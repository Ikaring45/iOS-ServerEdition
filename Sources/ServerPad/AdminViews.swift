import SwiftUI

@MainActor
struct ServerSettingsView: View {
    @ObservedObject var platform: ServerPlatform
    @State private var allowLAN = true
    @State private var autoStart = false

    var body: some View {
        Form {
            Section("稼働状態") {
                LabeledContent("状態", value: platform.status)
                Toggle("同じWi‑Fiからの接続を許可", isOn: $allowLAN)
                Toggle("アプリ起動時に自動起動", isOn: $autoStart)
                Button(platform.isRunning ? "サーバーを停止" : "サーバーを起動") {
                    Task { platform.isRunning ? await platform.stop() : await platform.start() }
                }
            }
            Section("HTTP") {
                HStack { Text("待受ポート"); Spacer(); TextField("8080", value: $platform.port, format: .number).multilineTextAlignment(.trailing).frame(width: 100).disabled(platform.isRunning) }
                Text("ポートを変更する場合は、サーバーを停止してから変更してください。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("サーバー設定")
    }
}

@MainActor
struct NetworkView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        List {
            Section("待受") {
                LabeledContent("ポート", value: String(platform.port))
                LabeledContent("状態", value: platform.status)
            }
            Section("接続アドレス") {
                if platform.accessURLs.isEmpty { Text("サーバー起動後に表示されます").foregroundStyle(.secondary) }
                ForEach(platform.accessURLs, id: \.self) { Text($0).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }
        }.navigationTitle("ポート／アドレス")
    }
}

@MainActor
struct StorageView: View {
    @ObservedObject var platform: ServerPlatform
    private var usedBytes: Int { platform.files.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        List {
            Section("ServerPad Shared") {
                LabeledContent("ファイル数", value: String(platform.files.count))
                LabeledContent("使用量", value: ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file))
                Button("ファイル一覧を更新") { platform.refreshFiles() }
            }
            Section("保存場所") { Text("アプリのDocuments/ServerPad Shared").font(.system(.body, design: .monospaced)) }
        }.navigationTitle("ストレージ")
    }
}

struct SystemView: View {
    var body: some View {
        List {
            Section("実行環境") {
                LabeledContent("OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("プロセッサ", value: ProcessInfo.processInfo.processorCount == 0 ? "不明" : "\(ProcessInfo.processInfo.processorCount) cores")
                LabeledContent("メモリ", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
            }
            Section("制約") { Text("iPadOSではアプリが前面にある間のサーバー稼働を前提にします。") }
        }.navigationTitle("システム")
    }
}

struct PluginsView: View {
    var body: some View {
        List {
            Section("プラグイン") {
                Label("現在は組み込み機能のみ", systemImage: "puzzlepiece.extension")
                Text("プラグインAPIを先に固定し、任意コードを直接実行しない方式で追加します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("予定") {
                Label("Bonjour公開", systemImage: "bonjour")
                Label("PIN認証", systemImage: "key")
                Label("ZIP操作", systemImage: "archivebox")
            }
        }.navigationTitle("プラグイン")
    }
}

struct BuildCodeView: View {
    private let code = """
    // システム構築の入口
    import SwiftUI
    import ServerPad

    @main
    struct MyApp: App {
        var body: some Scene {
            WindowGroup { ServerOSView() }
        }
    }
    """
    var body: some View { CodeTextView(title: "システム構築コード", code: code) }
}

@MainActor
struct ConfigCodeView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        let code = """
        {
          \"server\": {
            \"port\": \(platform.port),
            \"running\": \(platform.isRunning),
            \"sharedDirectory\": \"Documents/ServerPad Shared\"
          }
        }
        """
        return CodeTextView(title: "構成コード", code: code)
    }
}

@MainActor
struct CommandLineView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        let host = platform.localAddresses.first ?? "IPAD-IP"
        let commands = """
        # 状態確認
        curl http://\(host):\(platform.port)/api/status

        # ファイル一覧
        curl http://\(host):\(platform.port)/api/files

        # ファイル送信
        curl --data-binary @photo.jpg \\
          \"http://\(host):\(platform.port)/files/upload?name=photo.jpg\"
        """
        return CodeTextView(title: "コマンドライン", code: commands)
    }
}

private struct CodeTextView: View {
    let title: String
    let code: String
    var body: some View {
        ScrollView {
            Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle(title)
    }
}
