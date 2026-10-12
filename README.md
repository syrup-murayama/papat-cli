# papat CLI

**Version 0.1.1**

写真を書き出したフォルダを papat に送り、クライアントが選べるギャラリーを作るコマンドです。アップロードはバックグラウンドで続けられ、進み具合を後から確認できます。写真の中身を表示・分析しません。

対応環境は **macOS のみ**です。zsh と macOS 標準の `curl`、`sips`、`shasum`、`security`、Perl を使います。Python、exiftool、Homebrew などの追加インストールは不要です。

## インストール

最新版の ZIP とチェックサムは [papat.app/cli](https://papat.app/cli/) から入手してください。ZIP を展開し、ターミナルで展開先に移動して実行します。

```zsh
./install.sh
```

`~/.local/bin` が PATH にない場合は、インストーラーが `~/.zshrc` に追加する行を表示します。ターミナルを開き直して `papat --help` を実行してください。

インストール中の版は `papat --version` で確認できます。配布 ZIP のファイル名と SHA-256 は公式ページに掲載された最新版を使ってください。

## 初回ログイン

写真家ダッシュボードで発行した連携 API キーを Keychain に保存します。

```zsh
papat login
papat status
```

`papat login` が macOS Keychain の対話入力を開きます。API キーをコマンド引数、環境変数、AI エージェントとのチャットへ貼らないでください。接続に失敗したら、ダッシュボードでキーを再発行してからログインし直します。

## ギャラリー作成・アップロード

Lightroom Classic などから JPEG を書き出したフォルダを指定します。

```zsh
papat upload "$HOME/Pictures/案件/選定用" --title "春のカタログ" --days 7
```

ギャラリー作成直後に URL、パスコード、クライアントへ送る案内文が表示されます。その後、写真を最大4枚ずつ並行してアップロードします。標準出力を JSON にする場合は `--json` を付けます。

```zsh
papat upload "$HOME/Pictures/案件/選定用" --title "春のカタログ" --days 14 --key-color '#0066CC' --background
papat jobs
```

`--background` はターミナルから切り離して送信し、`papat jobs` と表示されたログファイルで進捗を確認します。通信が中断したり一部写真で失敗したりした場合は、同じフォルダで同じコマンドを再実行してください。成功済み写真をスキップし、未完了分から続けます。再開には元フォルダの写真が残っている必要があります。

送信前に一時コピーを作り、必要なら長辺2048px・sRGB・JPEGへ変換します。コピーから EXIF（GPS を含む）・XMP・IPTC・JPEG コメントなどのメタデータを取り除き、ICC カラープロファイルは保持します。ICC が無い場合は sRGB を付けます。除去・付与は JPEG のメタデータ領域だけを処理するため、縮小が不要な写真は画素データを再圧縮しません。元写真は変更しません。ファイル名stemが重複するフォルダは、ギャラリー内の写真名が衝突するため拒否します。

## その他のコマンド

```zsh
papat list
papat selections <sid> [--json]
papat extend <sid>
papat close <sid>
papat status [--json]
papat jobs [--json]
```

`extend` と `close` はギャラリーに対する操作です。実行前に sid を確認してください。延長料金・無料枠は papat の現行プランに従います。

## ローカルデータとセキュリティ

API キーは macOS Keychain に保存します。アップロードの再開状態と進捗ログは `~/.local/state/papat-cli/` に作られ、ユーザーだけが読める権限にします。完了後はパスコードと一時画像を削除します。失敗中は再開のためパスコードを含む作成情報がローカルに残ります。作業後に失敗 job を破棄したい場合は、状態ディレクトリを手動で削除してください。

CLI は写真の選定・閲覧をしません。AI エージェントで依頼する場合も、写真の中身を開かせず、アップロード完了後に URL とパスコードだけを受け取る運用にしてください。

## 開発・テスト

```zsh
tests/run.zsh
```

ソースリポジトリのテストは Keychain、HTTP API、`sips` をローカルモックへ差し替えます。本番 papat API や外部サービスへ接続せず、写真も送信しません。

変更履歴は [CHANGELOG.md](CHANGELOG.md) をご覧ください。

## 問い合わせ・セキュリティ

不具合の報告と機能要望は、このリポジトリの GitHub Issues で受け付けます。使い方の質問、アカウント、請求については [hello@papat.app](mailto:hello@papat.app) へご連絡ください。運営は1人のため、対応は届いた順になります。

**API キー、パスコード、ギャラリー URL、クライアント名、写真を公開 Issue に貼らないでください。** 脆弱性の報告も公開 Issue には書かず、[SECURITY.md](SECURITY.md) の手順で非公開にお知らせください。

## ライセンス

MIT License。著作権者は Murayama Photo Office です。詳細は [LICENSE](LICENSE) をご覧ください。
