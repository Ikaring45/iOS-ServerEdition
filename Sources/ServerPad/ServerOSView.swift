import SwiftUI

@MainActor
public struct ServerOSView: View {
    @StateObject private var platform: ServerPlatform

    public init(platform: ServerPlatform) { _platform = StateObject(wrappedValue: platform) }
    public init() { self.init(platform: ServerPlatform()) }

    public var body: some View {
        NavigationSplitView {
            List {
                Label("ダッシュボード", systemImage: "server.rack")
                Section("管理") {
                    NavigationLink { WebServerView(platform: platform) } label: { Label("Webサーバー公開", systemImage: "globe") }
                    NavigationLink { SiteView(platform: platform) } label: { Label("Webサイト", systemImage: "safari") }
                    NavigationLink { ServerSettingsView(platform: platform) } label: { Label("サーバー設定", systemImage: "gearshape.2") }
                    NavigationLink { NetworkView(platform: platform) } label: { Label("ポート／アドレス", systemImage: "network") }
                    NavigationLink { StorageView(platform: platform) } label: { Label("ストレージ", systemImage: "internaldrive") }
                    NavigationLink { SystemView() } label: { Label("システム", systemImage: "desktopcomputer") }
                }
                Section("開発") {
                    NavigationLink { PluginsView(platform: platform) } label: { Label("プラグイン", systemImage: "puzzlepiece.extension") }
                    NavigationLink { SSHView(platform: platform) } label: { Label("SSH", systemImage: "lock.shield") }
                    NavigationLink { TestReplayView(platform: platform) } label: { Label("テスト再生", systemImage: "play.rectangle") }
                    NavigationLink { BuildCodeView() } label: { Label("システム構築コード", systemImage: "hammer") }
                    NavigationLink { ConfigCodeView(platform: platform) } label: { Label("構成コード", systemImage: "curlybraces.square") }
                    NavigationLink { CommandLineView(platform: platform) } label: { Label("コマンドライン", systemImage: "terminal") }
                }
                NavigationLink { FilesView(platform: platform) } label: { Label("共有ファイル", systemImage: "folder") }
                NavigationLink { LogsView(platform: platform) } label: { Label("アクセスログ", systemImage: "text.alignleft") }
            }.navigationTitle("ServerPad")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Circle().fill(platform.isRunning ? .green : .secondary).frame(width: 12); Text(platform.status).font(.title2.bold()); Spacer() }
                    GroupBox("接続先") {
                        VStack(alignment: .leading, spacing: 8) {
                            if platform.accessURLs.isEmpty { Text("起動すると同じWi‑Fiから接続できるURLを表示します").foregroundStyle(.secondary) }
                            ForEach(platform.accessURLs, id: \.self) { Text($0).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("HTTP設定") {
                        HStack { Text("ポート"); Spacer(); TextField("8080", value: $platform.port, format: .number).multilineTextAlignment(.trailing).frame(width: 100).disabled(platform.isRunning) }
                    }
                    Button(platform.isRunning ? "サーバーを停止" : "サーバーを起動") {
                        Task { platform.isRunning ? await platform.stop() : await platform.start() }
                    }.buttonStyle(.borderedProminent).tint(platform.isRunning ? .red : .blue).controlSize(.large)
                    Text("iPadOSの制約により、サーバーはこのアプリを開いている間だけ確実に稼働します。インターネットへ直接公開する用途には使わないでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: 760)
            }.navigationTitle("ダッシュボード")
                .task {
                    if platform.autoStart { await platform.start() }
                }
        }
    }
}

private struct FilesView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        List {
            ForEach(platform.files) { file in
            VStack(alignment: .leading) { Text(file.name); Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
            .onDelete { offsets in
                for index in offsets { _ = platform.deleteFile(named: platform.files[index].name) }
            }
        }.navigationTitle("共有ファイル").toolbar { Button { platform.refreshFiles() } label: { Image(systemName: "arrow.clockwise") } }
    }
}

private struct LogsView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        List(platform.logs) { log in
            VStack(alignment: .leading) { Text(log.message).font(.system(.body, design: .monospaced)); Text(log.date, style: .time).font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("アクセスログ")
    }
}
