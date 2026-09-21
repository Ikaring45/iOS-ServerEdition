import SwiftUI

@MainActor
struct WebServerView: View {
    @ObservedObject var platform: ServerPlatform
    @Environment(\.openURL) private var openURL

    private var selfURL: URL { URL(string: platform.selfAccessURL)! }

    var body: some View {
        List {
            Section("Webサーバー") {
                LabeledContent("状態", value: platform.status)
                LabeledContent("自己アクセス", value: platform.selfAccessURL)
                Button("このiPadでWebページを開く") { openURL(selfURL) }
                    .disabled(!platform.isRunning)
            }
            Section("同じWi‑Fiからのアクセス") {
                if platform.accessURLs.isEmpty {
                    Text("サーバー起動後にアドレスを表示します").foregroundStyle(.secondary)
                }
                ForEach(platform.accessURLs, id: \.self) { address in
                    Link(address, destination: URL(string: address)!)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Section("公開エンドポイント") {
                WebEndpointRow(title: "トップページ", path: "/", platform: platform)
                WebEndpointRow(title: "状態JSON", path: "/api/status", platform: platform)
                WebEndpointRow(title: "ファイル一覧", path: "/files", platform: platform)
                WebEndpointRow(title: "ファイル一覧JSON", path: "/api/files", platform: platform)
            }
            Section("管理API") {
                Text("POST /api/server/start")
                Text("POST /api/server/stop")
                Text("POST /api/server/restart")
                Text("POST /api/command  {\"command\":\"status\"}")
                    .font(.system(.caption, design: .monospaced))
            }
            Section("インターネット公開") {
                Text("現在は同じWi‑Fi内への公開です。インターネット全体へ公開するには、別途HTTPS対応の中継・トンネルまたはルーター設定が必要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Webサーバー公開")
    }
}

private struct WebEndpointRow: View {
    let title: String
    let path: String
    @ObservedObject var platform: ServerPlatform

    var body: some View {
        let address = platform.selfAccessURL + path
        return Link(destination: URL(string: address)!) {
            HStack { Text(title); Spacer(); Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
        }.disabled(!platform.isRunning)
    }
}

@MainActor
struct ServerSettingsView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        Form {
            Section("稼働状態") {
                LabeledContent("状態", value: platform.status)
                Toggle("アプリ起動時に自動起動", isOn: $platform.autoStart)
                Button(platform.isRunning ? "サーバーを停止" : "サーバーを起動") {
                    Task { platform.isRunning ? await platform.stop() : await platform.start() }
                }
            }
            Section("HTTP") {
                HStack { Text("サーバー名"); Spacer(); TextField("ServerPad", text: $platform.serverName).multilineTextAlignment(.trailing).frame(width: 180) }
                HStack { Text("待受ポート"); Spacer(); TextField("8080", value: $platform.port, format: .number).multilineTextAlignment(.trailing).frame(width: 100).disabled(platform.isRunning) }
                HStack { Text("最大リクエスト"); Spacer(); TextField("25", value: $platform.maxRequestMiB, format: .number).multilineTextAlignment(.trailing).frame(width: 80); Text("MiB") }
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
                LabeledContent("Bonjour", value: platform.bonjourEnabled ? "有効（再起動後に公開）" : "無効")
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

@MainActor
struct PluginsView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        List {
            Section("プラグイン") {
                ForEach(platform.plugins) { plugin in
                    Toggle(isOn: Binding(get: { plugin.isEnabled }, set: { platform.setPluginEnabled(plugin.id, enabled: $0) })) {
                        VStack(alignment: .leading) {
                            Text(plugin.name)
                            Text(plugin.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section { Text("Bonjour公開は、プラグインを有効化してサーバーを再起動すると同一Wi‑Fi上へ公開されます。その他のプラグインは順次実装します。").font(.caption).foregroundStyle(.secondary) }
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
struct SiteView: View {
    @ObservedObject var platform: ServerPlatform

    var body: some View {
        List {
            Section("公開URL") {
                LabeledContent("サイト", value: platform.siteAccessURL)
                    .font(.system(.body, design: .monospaced))
                Link("このiPadでサイトを開く", destination: URL(string: platform.siteAccessURL)!)
                Link("ファイル管理・アップロード", destination: URL(string: platform.siteManageURL)!)
                    .disabled(!platform.isRunning)
            }
            Section("ファイル") {
                if platform.siteFiles.isEmpty {
                    Text("まだファイルがありません。index.htmlをアップロードしてください.")
                        .foregroundStyle(.secondary)
                }
                ForEach(platform.siteFiles) { file in
                    HStack {
                        Text(file.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { _ = platform.deleteSiteFile(named: platform.siteFiles[index].name) }
                }
                Button("一覧を更新") { platform.refreshSiteFiles() }
            }
            Section("アップロード") {
                Text("ブラウザで \(platform.siteManageURL) を開くと、サイト配信用ファイルをアップロードできます。")
                Text("curl --data-binary @index.html "\(platform.selfAccessURL)/site/upload?name=index.html"")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("対応") {
                Text("HTML / CSS / JavaScript / PNG / JPEG / GIF / WebP / SVG / JSON / PDF / TXT")
                    .font(.caption)
                Text("静的ファイル配信のみです。サーバー側でSwift、PHP、Pythonなどは実行しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Webサイト")
        .task { platform.refreshSiteFiles() }
    }
}

@MainActor
struct SSHView: View {
    @ObservedObject var platform: ServerPlatform
    @State private var showingPassword = false

    var body: some View {
        Form {
            Section("SSH管理サーバー") {
                Toggle("SSHを有効化", isOn: Binding(
                    get: { platform.sshEnabled },
                    set: { platform.setPluginEnabled("ssh", enabled: $0) }
                ))
                LabeledContent("状態", value: platform.sshStatus)
                HStack {
                    Text("待受ポート")
                    Spacer()
                    TextField("2222", value: $platform.sshPort, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Text("ユーザー名")
                    Spacer()
                    TextField("serverpad", text: $platform.sshUsername)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 150)
                }
                Button(platform.sshStatus == "稼働中" ? "SSHを停止" : "SSHを起動") {
                    Task {
                        _ = await platform.executeCommand(platform.sshStatus == "稼働中" ? "ssh stop" : "ssh start")
                    }
                }
            }
            Section("接続") {
                LabeledContent("コマンド", value: platform.sshCommand)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Text("パスワード")
                    Spacer()
                    Text(showingPassword ? platform.sshPassword : "••••••••••••••••")
                        .font(.system(.body, design: .monospaced))
                    Button(showingPassword ? "隠す" : "表示") { showingPassword.toggle() }
                }
                Button("パスワードを再生成") { platform.regenerateSSHPassword(); showingPassword = true }
                Text("同じWi‑Fi内からのみ接続してください。SSHではServerPad管理コマンドだけを実行できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SSH")
    }
}

@MainActor
struct ConfigCodeView: View {
    @ObservedObject var platform: ServerPlatform
    @State private var code = ""
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $code)
                .font(.system(.body, design: .monospaced))
                .padding(8)
            HStack {
                Button("現在の設定を読み込む") { code = platform.configurationJSON; message = "読み込みました" }
                Button("構成を適用") { message = platform.applyConfigurationJSON(code) ? "適用しました" : "JSONまたは値が不正です" }
                    .buttonStyle(.borderedProminent)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding()
        }
        .navigationTitle("構成コード")
        .onAppear { if code.isEmpty { code = platform.configurationJSON } }
    }
}

@MainActor
struct CommandLineView: View {
    @ObservedObject var platform: ServerPlatform
    @State private var command = ""
    @State private var history = ["ServerPad command console", "helpでコマンド一覧を表示"]
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(history.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Text("$").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                TextField("help", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .focused($commandFocused)
                    .onSubmit { runCommand() }
                Button("実行") { runCommand() }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("消去") { history = ["ServerPad command console"] }
            }.padding()
        }
        .navigationTitle("コマンドライン")
        .onAppear { commandFocused = true }
    }

    private func runCommand() {
        let input = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        command = ""
        history.append("$ \(input)")
        Task {
            let result = await platform.executeCommand(input)
            if !result.isEmpty { history.append(result) }
        }
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
