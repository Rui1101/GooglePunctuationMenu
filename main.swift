import AppKit
import Carbon.HIToolbox
import Foundation

@_silgen_name("mozc_ipc_call")
private func mozcIpcCall(_ request: UnsafePointer<UInt8>?, _ requestLength: Int, _ response: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ responseLength: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("mozc_ipc_free")
private func mozcIpcFree(_ pointer: UnsafeMutablePointer<UInt8>?)

enum Punctuation: UInt64, CaseIterable {
    case toutenKuten = 0, commaPeriod = 1
    var title: String { self == .toutenKuten ? "、。" : "，．" }
}

enum AppError: LocalizedError {
    case malformedProtocol, unsupportedValue(UInt64), ipc(Int32), missingConfig
    var errorDescription: String? {
        switch self {
        case .malformedProtocol: return "Google 日本語入力との通信データを読み取れませんでした。"
        case .unsupportedValue(let value): return "未対応の句読点設定値です: \(value)"
        case .ipc(let code): return "Google 日本語入力エンジンとの通信に失敗しました（IPC エラー \(code)）。"
        case .missingConfig: return "Google 日本語入力の設定を取得できませんでした。"
        }
    }
}

/// 必要な protobuf ワイヤー形式だけを扱う最小実装。
enum ProtoWire {
    static func readVarint(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<10 {
            guard offset < data.count else { throw AppError.malformedProtocol }
            let byte = data[offset]; offset += 1
            value |= UInt64(byte & 0x7f) << UInt64(shift * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw AppError.malformedProtocol
    }
    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat { var byte = UInt8(value & 0x7f); value >>= 7; if value != 0 { byte |= 0x80 }; data.append(byte) } while value != 0
    }
    static func skipValue(_ data: Data, _ offset: inout Int, wireType: UInt64) throws {
        switch wireType {
        case 0: _ = try readVarint(data, &offset)
        case 1: guard offset + 8 <= data.count else { throw AppError.malformedProtocol }; offset += 8
        case 2:
            let length = try readVarint(data, &offset)
            guard length <= UInt64(data.count - offset) else { throw AppError.malformedProtocol }; offset += Int(length)
        case 5: guard offset + 4 <= data.count else { throw AppError.malformedProtocol }; offset += 4
        default: throw AppError.malformedProtocol
        }
    }
    static func varintField(_ field: UInt64, in data: Data) throws -> UInt64? {
        var offset = 0
        while offset < data.count {
            let key = try readVarint(data, &offset)
            if key >> 3 == field {
                guard key & 7 == 0 else { throw AppError.malformedProtocol }
                return try readVarint(data, &offset)
            }
            try skipValue(data, &offset, wireType: key & 7)
        }
        return nil
    }
    static func bytesField(_ field: UInt64, in data: Data) throws -> Data? {
        var offset = 0
        while offset < data.count {
            let key = try readVarint(data, &offset)
            if key >> 3 == field {
                guard key & 7 == 2 else { throw AppError.malformedProtocol }
                let length = try readVarint(data, &offset)
                guard length <= UInt64(data.count - offset) else { throw AppError.malformedProtocol }
                let end = offset + Int(length); return data.subdata(in: offset..<end)
            }
            try skipValue(data, &offset, wireType: key & 7)
        }
        return nil
    }
    static func replacingVarintField(_ field: UInt64, value: UInt64, in data: Data) throws -> Data {
        var offset = 0; var result = Data(); var replaced = false
        while offset < data.count {
            let start = offset; let key = try readVarint(data, &offset)
            if key >> 3 == field {
                guard key & 7 == 0 else { throw AppError.malformedProtocol }
                _ = try readVarint(data, &offset)
                if !replaced { appendVarint(field << 3, to: &result); appendVarint(value, to: &result); replaced = true }
            } else {
                try skipValue(data, &offset, wireType: key & 7); result.append(data.subdata(in: start..<offset))
            }
        }
        if !replaced { appendVarint(field << 3, to: &result); appendVarint(value, to: &result) }
        return result
    }
}

/// ConfigDialog と同じ GET_CONFIG / SET_CONFIG を Mach IPC で送る。GUI は開かない。
final class MozcConfigClient {
    private let punctuationField: UInt64 = 45

    func currentPunctuation() throws -> Punctuation {
        let config = try getConfig()
        guard let raw = try ProtoWire.varintField(punctuationField, in: config) else { return .toutenKuten }
        guard let punctuation = Punctuation(rawValue: raw) else { throw AppError.unsupportedValue(raw) }
        return punctuation
    }
    func setPunctuation(_ punctuation: Punctuation) throws {
        let original = try getConfig()
        let updated = try ProtoWire.replacingVarintField(punctuationField, value: punctuation.rawValue, in: original)
        var request = Data([0x08, 0x07]) // Input.type = SET_CONFIG
        ProtoWire.appendVarint((5 << 3) | 2, to: &request) // Input.config
        ProtoWire.appendVarint(UInt64(updated.count), to: &request)
        request.append(updated)
        _ = try call(request)
    }
    private func getConfig() throws -> Data {
        let response = try call(Data([0x08, 0x06])) // Input.type = GET_CONFIG
        guard let config = try ProtoWire.bytesField(9, in: response) else { throw AppError.missingConfig }
        return config
    }
    private func call(_ request: Data) throws -> Data {
        var response: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = request.withUnsafeBytes { bytes in
            mozcIpcCall(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, &response, &length)
        }
        guard code == 0, let response else { throw AppError.ipc(code) }
        defer { mozcIpcFree(response) }
        return Data(bytes: response, count: length)
    }
}

/// 現在の入力ソース（Google 日本語入力のモードを含む）を TIS API で読む。権限は不要。
struct InputStatus: Equatable {
    let sourceID: String
    let modeID: String
    let name: String
    let label: String
    let isGoogleJapaneseInput: Bool
}

enum InputSourceReader {
    static func currentSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    static func status(of source: TISInputSource) -> InputStatus {
        let sourceID = string(source, kTISPropertyInputSourceID) ?? ""
        let modeID = string(source, kTISPropertyInputModeID) ?? ""
        let name = string(source, kTISPropertyLocalizedName) ?? sourceID
        return InputStatus(sourceID: sourceID, modeID: modeID, name: name,
                           label: label(sourceID: sourceID, modeID: modeID, name: name),
                           isGoogleJapaneseInput: sourceID.hasPrefix("com.google.inputmethod.Japanese"))
    }

    /// 純正の入力メニューに並ぶもの（有効で選択可能なキーボード入力ソース／入力モード）。
    static func selectableSources() -> [TISInputSource] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return [] }
        return (list as NSArray).map { ($0 as AnyObject) as! TISInputSource }
    }

    /// 純正メニューと同じアイコン。メニューバー／メニュー項目用に高さを揃えて返す。
    /// 画像ファイルを持たない入力ソース（ABC などのキーボードレイアウト）は、純正と同様に文字アイコンを描く。
    static func icon(of source: TISInputSource, height: CGFloat = 16) -> NSImage {
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) {
            let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
            if let original = NSImage(contentsOf: url), original.size.height > 0 {
                let resized = original.copy() as! NSImage
                resized.size = NSSize(width: original.size.width * height / original.size.height, height: height)
                resized.isTemplate = url.deletingPathExtension().lastPathComponent.hasSuffix("Template")
                return resized
            }
        }
        // kTISPropertyIconRef は汎用のキーボードアイコンになることが多いので使わない。
        return labelIcon(status(of: source).label, height: height)
    }

    /// 角丸の枠に文字を入れたテンプレート画像（ライト／ダークモードで自動的に色が変わる）。
    static func labelIcon(_ text: String, height: CGFloat = 16) -> NSImage {
        let font = NSFont.systemFont(ofSize: height * 0.7, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = max(height, ceil(textSize.width) + 6)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.2
            NSColor.black.setStroke(); frame.stroke()
            (text as NSString).draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                                y: (rect.height - textSize.height) / 2),
                                    withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// アイコンが取れないときの代替表示。入力モード ID（com.apple.inputmethod.*）を優先する。
    private static func label(sourceID: String, modeID: String, name: String) -> String {
        for key in [modeID, sourceID] where !key.isEmpty {
            if key.hasSuffix("HalfWidthKana") { return "ｱ" }
            if key.hasSuffix("Katakana") { return "ア" }
            if key.hasSuffix("FullWidthRoman") { return "Ａ" }
            if key.hasSuffix(".Roman") { return "A" }
            if key.hasSuffix(".Japanese") || key.hasSuffix(".Hiragana") || key.hasSuffix(".base") { return "あ" }
        }
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Google 日本語入力に同梱されているツール（存在するものだけメニューに出す）。
enum GoogleJapaneseInputTools {
    static let directory = URL(fileURLWithPath: "/Applications/GoogleJapaneseInput.localized")
    static let items: [(title: String, app: String)] = [
        ("文字パレット", "CharacterPalette.app"),
        ("手書き文字入力", "HandWriting.app"),
        ("辞書ツール", "DictionaryTool.app"),
        ("単語登録", "WordRegisterDialog.app"),
        ("環境設定…", "ConfigDialog.app"),
        ("Google 日本語入力について", "AboutDialog.app"),
    ]
    static func available() -> [(title: String, url: URL)] {
        items.compactMap { item in
            let url = directory.appendingPathComponent(item.app)
            return FileManager.default.fileExists(atPath: url.path) ? (item.title, url) : nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = MozcConfigClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let showInputModeKey = "ShowInputMode"
    private var isApplying = false
    private var punctuation: Punctuation?
    private var inputStatus: InputStatus?
    private var inputIcon: NSImage?
    private var refreshGeneration = 0
    private var pollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private var showInputMode: Bool {
        get { UserDefaults.standard.object(forKey: showInputModeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showInputModeKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.toolTip = "入力ソースと句読点（⌘. で句読点を切り替え）"
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self; statusItem.menu = menu
        registerHotKey()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        // 入力モード変更で通知が来ない環境への保険。TIS を読むだけなので負荷はごく小さい。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkInputSource() }
        checkInputSource(force: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    func menuWillOpen(_ menu: NSMenu) { checkInputSource(force: true) }

    @objc private func inputSourceDidChange() { checkInputSource() }

    private func checkInputSource(force: Bool = false) {
        let source = InputSourceReader.currentSource()
        let status = source.map(InputSourceReader.status(of:))
        guard force || status != inputStatus else { return }
        let sourceChanged = status != inputStatus
        inputStatus = status
        inputIcon = source.map { InputSourceReader.icon(of: $0) }
        refreshUI()
        // Google 日本語入力に入ったとき・メニューを開いたときに句読点を読み直す（設定画面での変更にも追従）。
        if status?.isGoogleJapaneseInput == true, force || sourceChanged || punctuation == nil { refreshPunctuation() }
    }

    private func refreshPunctuation() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let value = try? client.currentPunctuation()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.refreshGeneration, !self.isApplying else { return }
                self.punctuation = value
                self.refreshUI()
            }
        }
    }

    /// メニューバー：純正と同じ入力ソースのアイコン ＋ 句読点（Google 日本語入力のときだけ）。
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let isGoogle = inputStatus?.isGoogleJapaneseInput ?? true
        let punct = isApplying ? "…" : (punctuation?.title ?? "？")
        if showInputMode {
            button.image = inputIcon
            let mode = inputIcon == nil ? (inputStatus?.label ?? "?") : ""
            button.title = isGoogle ? mode + punct : mode
        } else {
            button.image = nil
            button.title = punct
        }
    }

    private func refreshUI() {
        updateStatusButton()
        rebuildMenu()
    }

    /// 純正の入力メニューと同じ並び：入力ソース一覧 → 入力メソッドのメニュー → 共通項目。
    private func rebuildMenu() {
        menu.removeAllItems()
        let current = inputStatus

        // 1. 入力ソース／入力モードの一覧（選択で切り替え）
        for source in InputSourceReader.selectableSources() {
            let status = InputSourceReader.status(of: source)
            let item = NSMenuItem(title: status.name, action: #selector(selectInputSource(_:)), keyEquivalent: "")
            item.target = self
            item.image = InputSourceReader.icon(of: source)
            item.representedObject = source
            item.state = status.sourceID == current?.sourceID && status.modeID == current?.modeID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 2. Google 日本語入力のメニュー（句読点 ＋ 同梱ツール）
        let header = NSMenuItem(title: "句読点", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        for item in Punctuation.allCases {
            let menuItem = NSMenuItem(title: item.title, action: #selector(selectPunctuation(_:)), keyEquivalent: "")
            menuItem.target = self; menuItem.representedObject = NSNumber(value: item.rawValue)
            menuItem.state = item == punctuation ? .on : .off; menuItem.isEnabled = !isApplying
            menuItem.indentationLevel = 1; menu.addItem(menuItem)
        }
        let shortcut = NSMenuItem(title: "句読点を切り替え（⌘.）", action: #selector(togglePunctuation), keyEquivalent: "")
        shortcut.target = self; shortcut.isEnabled = !isApplying; shortcut.indentationLevel = 1; menu.addItem(shortcut)
        if current?.isGoogleJapaneseInput ?? false {
            let tools = GoogleJapaneseInputTools.available()
            if !tools.isEmpty { menu.addItem(.separator()) }
            for tool in tools {
                let item = NSMenuItem(title: tool.title, action: #selector(openTool(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = tool.url; menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // 3. 純正メニューの共通項目
        let emoji = NSMenuItem(title: "絵文字と記号を表示", action: #selector(showCharacterPalette), keyEquivalent: "")
        emoji.target = self; menu.addItem(emoji)
        let openKeyboard = NSMenuItem(title: "\"キーボード\"設定を開く…", action: #selector(openKeyboardSettings), keyEquivalent: "")
        openKeyboard.target = self; menu.addItem(openKeyboard)
        menu.addItem(.separator())

        // 4. このアプリの設定
        let showMode = NSMenuItem(title: "メニューバーに入力ソースも表示", action: #selector(toggleShowInputMode), keyEquivalent: "")
        showMode.target = self; showMode.state = showInputMode ? .on : .off; menu.addItem(showMode)
        menu.addItem(NSMenuItem(title: "Google Punctuation Menu を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectInputSource(_ sender: NSMenuItem) {
        guard let object = sender.representedObject else { return }
        TISSelectInputSource(((object as AnyObject) as! TISInputSource))
        checkInputSource(force: true)
    }
    @objc private func selectPunctuation(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber, let target = Punctuation(rawValue: number.uint64Value) else { return }
        perform { client in try client.setPunctuation(target); return target }
    }
    @objc private func togglePunctuation() {
        perform { client in
            let next: Punctuation = try client.currentPunctuation() == .toutenKuten ? .commaPeriod : .toutenKuten
            try client.setPunctuation(next)
            return next
        }
    }
    /// IPC はバックグラウンドで実行し、メインスレッド（メニューバー）を固めない。
    private func perform(_ work: @escaping (MozcConfigClient) throws -> Punctuation) {
        guard !isApplying else { return }
        isApplying = true
        refreshGeneration += 1 // 実行中の読み直し結果は捨てる
        refreshUI()
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(client) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isApplying = false
                switch result {
                case .success(let value): self.punctuation = value
                case .failure(let error):
                    self.showAlert(title: "設定を適用できませんでした",
                                   message: error.localizedDescription + "\nGoogle 日本語入力が有効になっていることを確認してください。")
                }
                self.refreshUI()
            }
        }
    }
    @objc private func toggleShowInputMode() { showInputMode.toggle(); refreshUI() }
    @objc private func showCharacterPalette() { NSApp.orderFrontCharacterPalette(nil) }
    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Keyboard.prefPane"))
    }
    @objc private func openTool(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePunctuation() }; return noErr
        }, 1, &eventType, userData, &eventHandler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x47504D31), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSLog("GooglePunctuationMenu: ⌘. の登録に失敗しました (\(status))") }
    }
    private func showAlert(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning; alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    do {
        let client = MozcConfigClient()
        let current = try client.currentPunctuation()
        try client.setPunctuation(current)  // 現在値を再適用するだけで、内容は変更しない。
        guard try client.currentPunctuation() == current else { throw AppError.malformedProtocol }
        print("direct IPC self-test passed: \(current.title)")
        exit(0)
    } catch {
        fputs("direct IPC self-test failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
