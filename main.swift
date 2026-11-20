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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = MozcConfigClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var isApplying = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.toolTip = "Google 日本語入力：句読点を切り替え（⌘.）"
        menu.delegate = self; statusItem.menu = menu
        registerHotKey(); rebuildMenu()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let current = try? client.currentPunctuation()
        statusItem.button?.title = isApplying ? "…" : (current?.title ?? "？")
        let title = NSMenuItem(title: "Google 日本語入力の句読点", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title); menu.addItem(.separator())
        for punctuation in Punctuation.allCases {
            let item = NSMenuItem(title: punctuation.title, action: #selector(selectPunctuation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = NSNumber(value: punctuation.rawValue)
            item.state = punctuation == current ? .on : .off; item.isEnabled = !isApplying; menu.addItem(item)
        }
        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "切り替え（⌘.）", action: #selector(togglePunctuation), keyEquivalent: "")
        shortcut.target = self; shortcut.isEnabled = !isApplying; menu.addItem(shortcut)
        let openConfig = NSMenuItem(title: "Google 日本語入力の設定を開く…", action: #selector(openConfigDialog), keyEquivalent: "")
        openConfig.target = self; menu.addItem(openConfig)
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    @objc private func selectPunctuation(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber, let punctuation = Punctuation(rawValue: number.uint64Value) else { return }
        apply(punctuation)
    }
    @objc private func togglePunctuation() {
        guard let current = try? client.currentPunctuation() else { showAlert(title: "現在の設定を読めませんでした", message: "Google 日本語入力が有効になっていることを確認してください。"); return }
        apply(current == .toutenKuten ? .commaPeriod : .toutenKuten)
    }
    private func apply(_ punctuation: Punctuation) {
        guard !isApplying else { return }
        isApplying = true; rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try self?.client.setPunctuation(punctuation) }
            DispatchQueue.main.async {
                guard let self else { return }; self.isApplying = false; self.rebuildMenu()
                if case .failure(let error) = result { self.showAlert(title: "設定を適用できませんでした", message: error.localizedDescription) }
            }
        }
    }
    @objc private func openConfigDialog() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/GoogleJapaneseInput.localized/ConfigDialog.app")) }
    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePunctuation() }; return noErr
        }, 1, &eventType, userData, &eventHandler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x47504D31), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
