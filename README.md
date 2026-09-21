# ServerPad

iPadを、同じWi‑Fi内で使う小型HTTPサーバーにするSwift Packageです。サーバーOS風の管理画面、Webページ、JSON API、ファイル共有を含みます。

## 開発方式（推奨構成）

このリポジトリをGitHubのSwift Packageとして本体にします。画面、状態管理、HTTPランタイム、API、ファイル共有、テストはすべてこのPackageを正本にし、iPad側のAppプロジェクトは起動用の薄いホストにします。

```text
GitHub: ServerPad
└─ Sources/ServerPad/       ← 本体。ここだけを開発・更新する
   ├─ ServerOSView.swift    ← 管理画面
   ├─ ServerPlatform.swift  ← 状態・サービス管理
   ├─ HTTPServer.swift      ← NWListenerによる待受
   └─ HTTPTypes.swift       ← HTTP解析・応答

iPad Swift Playground App  ← 表示用の箱
└─ ServerPadApp.swift       ← @main と ServerOSView() だけ
```

この分離により、GitHub上のPackageを更新してバージョンを上げれば、ホスト側のコードを編集せずに本体を更新できます。ホスト側に残るのは、Swift Packageでは提供できないアプリ署名、`Info.plist`、権限、`@main` です。

## Swift Playgroundsへの導入

1. このフォルダをGitHubリポジトリとして公開します。
2. iPadのSwift Playgroundsで新しい「App」プロジェクトを作成します。
3. Swift Playgroundsのパッケージ追加画面から、GitHubリポジトリURLをSwift Package依存関係として追加します。ローカル開発中は、同じPackageフォルダをローカル依存関係として追加しても構いません。
4. App側には、次のホストコードだけを置きます。

```swift
import SwiftUI

@main
struct ServerPadApp: App {
    var body: some Scene {
        WindowGroup { ServerOSView() }
    }
}
```

5. App設定でローカルネットワーク利用理由を追加します。Xcodeでは `Info.plist` の `NSLocalNetworkUsageDescription` に「同じWi‑Fi内の端末へWeb・API・ファイル共有を提供するため」などを設定します。
   Bonjour公開を使う場合は、`NSBonjourServices` に `_http._tcp` も追加します。見本は `Examples/Info.plist.additions.xml` にあります。
6. 実行して「サーバーを起動」を押し、表示されたURLを同じWi‑Fi内のPCやスマートフォンで開きます。

`Examples/ServerPadApp.swift` と `Examples/Info.plist.additions.xml` は、この薄いホストをそのまま確認するための見本です。ホスト側へ本体コードをコピーする運用には戻しません。

## エンドポイント

| 方法 | パス | 内容 |
|---|---|---|
| GET | `/` | Webトップ |
| GET | `/api/status` | 稼働状態JSON |
| GET | `/api/files` | ファイル一覧JSON |
| GET | `/files` | ファイル一覧ページ |
| GET | `/files/{name}` | ファイル取得 |
| POST | `/files/upload?name={name}` | リクエスト本文をファイルとして保存 |

## Webサーバーとしての利用

アプリの「Webサーバー公開」画面から、同じiPadでは `http://127.0.0.1:ポート`、同じWi‑Fi上の別端末では表示されたLANアドレスを開けます。Bonjour公開プラグインを有効にすると `_http._tcp` として発見できます。インターネット全体への公開には、HTTPS対応の中継・トンネルまたはルーター設定が別途必要です。

アップロード例：

```bash
curl --data-binary @photo.jpg "http://IPAD-IP:8080/files/upload?name=photo.jpg"
```

## 重要な制約

- iPadOSでは一般的なサーバーOSのような24時間バックグラウンド常駐はできません。アプリが前面にある間の利用を前提にしています。
- 現版に認証・TLS・削除APIはありません。信頼できる家庭内LANだけで使い、ルーターのポート開放はしないでください。
- 1リクエスト上限は25 MiBです。大容量転送、Range、multipart/form-data、WebSocketには未対応です。
- 共有ファイルはアプリのDocuments内 `ServerPad Shared` に保存されます。

## 次段階

Bonjour広告、PIN認証、multipartアップロード、ZIP操作、ストレージ使用量、サービス別スイッチ、バックグラウンド移行時の明示停止を追加できます。

## CIとRelease

GitHub ActionsでmacOS上の `swift test` を自動実行します。Releaseを作るときは、GitHub上でタグを作成するか、ローカルGitで次を実行します。

```bash
git tag v0.1.0
git push origin v0.1.0
```

`v*.*.*` のタグがpushされると、テスト成功後にソースZIP付きのGitHub Releaseを自動作成します。
