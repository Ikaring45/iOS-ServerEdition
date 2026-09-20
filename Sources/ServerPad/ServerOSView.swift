import SwiftUI

@MainActor
public struct ServerOSView: View {
    @StateObject private var platform: ServerPlatform

    @MainActor
    public init(platform: ServerPlatform = ServerPlatform()) { _platform = StateObject(wrappedValue: platform) }

    public var body: some View {
        NavigationSplitView {
            List {
                Label("ダッシュボード", systemImage: "server.rack")
                NavigationLink { FilesView(platform: platform) } label: { Label("共有ファイル", systemImage: "folder") }
