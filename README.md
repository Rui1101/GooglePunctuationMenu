# Google Punctuation Menu（研究室内配布版）

Google 日本語入力の「句読点の種類」を、メニューバーまたは `⌘ + .` で切り替える macOS アプリです。左右どちらの Command キーでも使えます。設定ウィンドウは開きません。

これは研究室内利用を想定した**非公式ツール**です。Google LLC および Google 日本語入力の公式製品ではなく、承認・提携関係もありません。

## 起動

`GooglePunctuationMenu.app` をダブルクリックします。メニューバーの `、。` または `，．` をクリックすると選べます。`⌘ + .` でも2種類を相互に切り替えます。

## 要件

- macOS 12 以降
- Google 日本語入力がインストール済みで、入力ソースとして一度有効化されていること
- Google 日本語入力 3.34.6260.1 で確認

この配布物は Universal Binary です。Apple Silicon Mac と Intel Mac の両方に対応します。

## 動作と安全策

- 対象は `、。` と `，．` の2種類だけです。
- 設定ファイルを直接変更しません。
- `ConfigDialog.app` と同じ `GET_CONFIG` / `SET_CONFIG` Protocol Buffers 要求を、Google 日本語入力の Converter Mach サービスへ直接送ります。
- 変換エンジンの設定更新処理を直接実行するため、設定画面やアクセシビリティ権限は不要です。
- Google 日本語入力が未起動の場合は、同入力ソースを一度選択してから使ってください。

## 配布上の注意

- このリポジトリ／ZIP には、Google 日本語入力のアプリ本体、アイコン、Framework、設定ファイル、ログ、`.session.ipc` を含めません。
- 動作は Google 日本語入力の非公開実装に依存するため、Google 日本語入力の更新後は動作確認が必要です。
- 研究室外へ配布する場合は、Developer ID 署名と公証、ならびに利用許諾の確認を行ってください。
- Mozc 関連の表示は `THIRD_PARTY_NOTICES.md` を参照してください。
- Google 日本語入力の将来の更新で設定形式・挙動が変わる可能性があります。
