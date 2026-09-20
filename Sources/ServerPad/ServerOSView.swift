import SwiftUI

public struct ServerOSView: View {
    @StateObject private var platform: ServerPlatform

    public init(platform: ServerPlatform = ServerPlatform()) { _platform = StateObject(wrappedValue: platform) }

    public var body: some View {
        NavigationSplitView {
            List {
                Label("ダッシュボード", systemImage: "server.rack")
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
                        HStack { Text("ポート"); Spacer(); TextField("8080", value: $platform.port, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).disabled(platform.isRunning) }
                    }
                    Button(platform.isRunning ? "サーバーを停止" : "サーバーを起動") {
                        Task { platform.isRunning ? await platform.stop() : await platform.start() }
                    }.buttonStyle(.borderedProminent).tint(platform.isRunning ? .red : .blue).controlSize(.large)
                    Text("iPadOSの制約により、サーバーはこのアプリを開いている間だけ確実に稼働します。インターネットへ直接公開する用途には使わないでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: 760)
            }.navigationTitle("ダッシュボード")
        }
    }
}

private struct FilesView: View {
    @ObservedObject var platform: ServerPlatform
    var body: some View {
        List(platform.files) { file in
            VStack(alignment: .leading) { Text(file.name); Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
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

