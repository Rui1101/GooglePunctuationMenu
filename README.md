# Google Punctuation Menu

Google 日本語入力の「句読点の種類」を、メニューバーまたは `⌘ + .` で切り替える macOS アプリです。左右どちらの Command キーでも使えます。設定ウィンドウは開きません。

これは**非公式ツール**です。Google LLC および Google 日本語入力の公式製品ではなく、承認・提携関係もありません。

## Xcode でのビルド

1. `GooglePunctuationMenu.xcodeproj` を Xcode で開きます。
2. Target **GooglePunctuationMenu** の **Signing & Capabilities** で、必要に応じて Team と Bundle Identifier を自分のものへ変更します。自分でビルドして配布する場合は、Bundle Identifier を自分のものに変更してください。
3. 実行先に **My Mac** を選び、`⌘B` でビルドします。メニューバー常駐アプリなので、Dock には表示されません。

コマンドラインでも次で Release ビルドできます。

```sh
xcodebuild -project GooglePunctuationMenu.xcodeproj \
  -scheme GooglePunctuationMenu -configuration Release build
```

初期設定は macOS 12 以降です。配布用アーカイブは Xcode の **Product > Archive** から作成します。

## 起動

[Releases](https://github.com/Rui1101/GooglePunctuationMenu/releases) から zip をダウンロードして展開し、`GooglePunctuationMenu.app` をダブルクリックします。配布バイナリは Apple の公証を受けていないため、初回は右クリック →「開く」で起動してください（または システム設定 > プライバシーとセキュリティ から許可）。メニューバーの `、。` または `，．` をクリックすると選べます。`⌘ + .` でも2種類を相互に切り替えます。

## 要件

- macOS 12 以降
- Google 日本語入力がインストール済みで、入力ソースとして一度有効化されていること
- Google 日本語入力 3.34.6260.1 で確認

Releases の配布物は Universal Binary です。Apple Silicon Mac と Intel Mac の両方に対応します。

## 動作と安全策

- 対象は `、。` と `，．` の2種類だけです。
- 設定ファイルを直接変更しません。
- `ConfigDialog.app` と同じ `GET_CONFIG` / `SET_CONFIG` Protocol Buffers 要求を、Google 日本語入力の Converter Mach サービスへ直接送ります。
- 変換エンジンの設定更新処理を直接実行するため、設定画面やアクセシビリティ権限は不要です。
- Google 日本語入力が未起動の場合は、同入力ソースを一度選択してから使ってください。

## 配布上の注意

- このリポジトリ／ZIP には、Google 日本語入力のアプリ本体、アイコン、Framework、設定ファイル、ログ、`.session.ipc` を含めません。
- 動作は Google 日本語入力の非公開実装に依存するため、Google 日本語入力の更新後は動作確認が必要です。
- Mozc 関連の表示は `THIRD_PARTY_NOTICES.md` を参照してください。
- Google 日本語入力の将来の更新で設定形式・挙動が変わる可能性があります。

## ライセンス

BSD 3-Clause License。詳細は `LICENSE` を参照してください。
