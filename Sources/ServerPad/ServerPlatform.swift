import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

public struct ServerLog: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
}

public struct SharedFile: Identifiable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: Int
    public let modified: Date
}

public struct ServerPlugin: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public var isEnabled: Bool

    public init(id: String, name: String, summary: String, isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isEnabled = isEnabled
    }
}

@MainActor
public final class ServerPlatform: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "停止中"
    @Published public private(set) var logs: [ServerLog] = []
    @Published public private(set) var files: [SharedFile] = []
    @Published public var port: UInt16 = 8080 { didSet { saveSettings() } }
    @Published public var serverName = "ServerPad" { didSet { saveSettings() } }
    @Published public var maxRequestMiB: Int = 25 { didSet { saveSettings() } }
    @Published public var autoStart = false { didSet { saveSettings() } }
    @Published public private(set) var localAddresses: [String] = []
    @Published public private(set) var plugins: [ServerPlugin] = []
    @Published public var sshPort: UInt16 = 2222 { didSet { saveSettings() } }
    @Published public var sshUsername = "serverpad" { didSet { saveSettings() } }
    @Published public private(set) var sshPassword = ""

    private var server: HTTPServer?
    private var sshServer: SSHServer?
    private let filesURL: URL
    private let settings = UserDefaults.standard
    private let settingsKey = "ServerPad.settings.v1"

    public init(filesURL: URL? = nil) {
        self.filesURL = filesURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ServerPad Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.filesURL, withIntermediateDirectories: true)
        if let data = settings.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) {
            self.port = saved.port
            self.serverName = saved.serverName
            self.maxRequestMiB = saved.maxRequestMiB
            self.autoStart = saved.autoStart
            self.sshPort = saved.sshPort
            self.sshUsername = saved.sshUsername
            self.sshPassword = saved.sshPassword
            self.plugins = Self.defaultPlugins.map { plugin in
                var plugin = plugin
                plugin.isEnabled = saved.enabledPluginIDs.contains(plugin.id)
                return plugin
            }
        } else {
            self.plugins = Self.defaultPlugins
        }
        if self.sshPassword.isEmpty { self.sshPassword = Self.generatePassword() }
        refreshFiles()
    }

    public var accessURLs: [String] { localAddresses.map { "http://\($0):\(port)" } }
    public var selfAccessURL: String { "http://127.0.0.1:\(port)" }
    public var bonjourEnabled: Bool { plugins.first(where: { $0.id == "bonjour" })?.isEnabled == true }
    public var sshEnabled: Bool { plugins.first(where: { $0.id == "ssh" })?.isEnabled == true }
    public var sshStatus: String { sshServer?.status ?? "停止中" }
    public var sshCommand: String { "ssh \(sshUsername)@IPAD-IP -p \(sshPort)" }

    public func regenerateSSHPassword() { sshPassword = Self.generatePassword(); saveSettings(); record("SSHパスワードを再生成") }

    public var configurationJSON: String {
        let snapshot = SettingsSnapshot(port: port, serverName: serverName, maxRequestMiB: maxRequestMiB, autoStart: autoStart, sshPort: sshPort, sshUsername: sshUsername, sshPassword: sshPassword, enabledPluginIDs: plugins.filter(\.isEnabled).map(\.id))
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    @discardableResult
    public func applyConfigurationJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let saved = try? JSONDecoder().decode(SettingsSnapshot.self, from: data),
              saved.port > 0,
              saved.maxRequestMiB > 0,
              saved.maxRequestMiB <= 512 else { return false }
        port = saved.port
        serverName = saved.serverName.isEmpty ? "ServerPad" : saved.serverName
        maxRequestMiB = saved.maxRequestMiB
        autoStart = saved.autoStart
        for index in plugins.indices {
            plugins[index].isEnabled = saved.enabledPluginIDs.contains(plugins[index].id)
        }
        saveSettings()
        record("構成コードを適用")
        return true
    }

    public func setPluginEnabled(_ id: String, enabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].isEnabled = enabled
        saveSettings()
        record("プラグイン\(enabled ? "有効化" : "無効化"): \(plugins[index].name)")
    }

    public func executeCommand(_ input: String) async -> String {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "" }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let command = parts.first?.lowercased() else { return "" }

        switch command {
        case "help", "?":
            return Self.commandHelp
        case "status":
            return "name=\(serverName) status=\(status) running=\(isRunning) port=\(port) files=\(files.count) bonjour=\(bonjourEnabled)"
        case "start":
            await start()
            return status
        case "stop":
            await stop()
            return status
        case "restart":
            await stop()
            await start()
            return status
        case "port":
            guard parts.count > 1, let value = UInt16(parts[1]), value > 0 else { return "使い方: port 8080" }
            guard !isRunning else { return "停止中に変更してください" }
            port = value
            return "port=\(port)"
        case "name":
            guard parts.count > 1 else { return "name=\(serverName)" }
            let value = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "使い方: name ServerPad" }
            serverName = String(value.prefix(64))
            return "name=\(serverName)"
        case "url", "urls":
            let urls = [selfAccessURL] + accessURLs
            return urls.joined(separator: "\n")
        case "files", "ls":
            refreshFiles()
            return files.isEmpty ? "共有ファイルはありません" : files.map { "\($0.name)\t\($0.bytes) bytes" }.joined(separator: "\n")
        case "delete", "rm":
            guard parts.count > 1 else { return "使い方: delete filename" }
            return deleteFile(named: parts[1]) ? "削除しました: \(parts[1])" : "削除できません: \(parts[1])"
        case "plugins":
            return plugins.map { "\($0.id)\t\($0.isEnabled ? "on" : "off")\t\($0.name)" }.joined(separator: "\n")
        case "plugin":
            guard parts.count > 2, ["on", "off"].contains(parts[2].lowercased()) else { return "使い方: plugin bonjour on|off" }
            let id = parts[1]
            guard plugins.contains(where: { $0.id == id }) else { return "不明なプラグイン: \(id)" }
            setPluginEnabled(id, enabled: parts[2].lowercased() == "on")
            return "plugin \(id)=\(parts[2].lowercased())（反映には再起動が必要）"
        case "config":
            return configurationJSON
        case "ssh":
            if parts.count == 1 { return "ssh status=\(sshStatus) enabled=\(sshEnabled) port=\(sshPort) user=\(sshUsername)\\n接続: \(sshCommand)" }
            switch parts[1].lowercased() {
            case "start": await startSSH(); return sshStatus
            case "stop": await stopSSH(); return sshStatus
            case "port":
                guard parts.count > 2, let value = UInt16(parts[2]), value > 0 else { return "使い方: ssh port 2222" }
                guard (sshServer?.isRunning ?? false) == false else { return "SSHを停止してから変更してください" }
                sshPort = value; return "ssh-port=\(sshPort)"
            case "password": return "ssh-user=\(sshUsername) password=\(sshPassword)"
            default: return "使い方: ssh [status|start|stop|port 2222|password]"
            }
        case "curl":
            return "curl --data-binary @FILE \"\(selfAccessURL)/files/upload?name=FILE\""
        default:
            return "不明なコマンド: \(command)（helpで一覧）"
        }
    }

    public func start() async {
        guard !isRunning else { return }
        status = "起動中…"
        let runtime = HTTPServer(maximumRequestBytes: maxRequestMiB * 1024 * 1024, serviceName: bonjourEnabled ? serverName : nil) { [weak self] request in
            guard let self else { return .text("Unavailable", status: 503) }
            return await self.route(request)
        }
        do {
            try await runtime.start(port: port)
            server = runtime; isRunning = true; status = "稼働中"
            localAddresses = Self.addresses()
            if sshEnabled { await startSSH() }
            record("HTTPサーバーをポート \(port) で開始")
        } catch {
            status = "起動失敗: \(error.localizedDescription)"
            record(status)
        }
    }

    public func stop() async {
        await stopSSH()
        await server?.stop(); server = nil; isRunning = false; status = "停止中"
        record("HTTPサーバーを停止")
    }

    public func refreshFiles() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        files = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return SharedFile(name: url.lastPathComponent, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func deleteFile(named name: String) -> Bool {
        guard let safe = safeName(name) else { return false }
        do {
            try FileManager.default.removeItem(at: filesURL.appendingPathComponent(safe))
            refreshFiles()
            record("ファイルを削除: \(safe)")
            return true
        } catch {
            record("ファイル削除失敗: \(safe)")
            return false
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        record("\(request.method) \(request.target)")
        if request.path == "/" && ["GET", "HEAD"].contains(request.method) { return .text(Self.homeHTML, contentType: "text/html; charset=utf-8") }
        if request.path == "/api/status" && request.method == "GET" {
            return .json(APIStatus(name: serverName, status: status, running: isRunning, port: port, files: files.count, bonjour: bonjourEnabled, urls: [selfAccessURL] + accessURLs))
        }
        if request.path == "/api/config" && request.method == "GET" { return .text(configurationJSON, contentType: "application/json; charset=utf-8") }
        if request.path == "/api/plugins" && request.method == "GET" { return .json(plugins) }
        if request.path == "/api/server/start" && request.method == "POST" { await start(); return .json(APIStatus(name: serverName, status: status, running: isRunning, port: port, files: files.count, bonjour: bonjourEnabled, urls: [selfAccessURL] + accessURLs)) }
        if request.path == "/api/server/stop" && request.method == "POST" { await stop(); return .json(APIStatus(name: serverName, status: status, running: isRunning, port: port, files: files.count, bonjour: bonjourEnabled, urls: [selfAccessURL] + accessURLs)) }
        if request.path == "/api/server/restart" && request.method == "POST" { await stop(); await start(); return .json(APIStatus(name: serverName, status: status, running: isRunning, port: port, files: files.count, bonjour: bonjourEnabled, urls: [selfAccessURL] + accessURLs)) }
        if request.path == "/api/command" && request.method == "POST" {
            let command = request.query["command"] ?? ((try? JSONDecoder().decode(APICommand.self, from: request.body))?.command ?? "")
            guard !command.isEmpty else { return .json(APICommandResult(output: "commandが必要です"), status: 400) }
            return .json(APICommandResult(output: await executeCommand(command)))
        }
        if request.path == "/api/files" && request.method == "GET" { refreshFiles(); return .json(files) }
        if request.path == "/files" && request.method == "GET" { refreshFiles(); return .text(fileIndexHTML(), contentType: "text/html; charset=utf-8") }
        if request.path == "/files/upload" && request.method == "POST" { return upload(request) }
        if request.path.hasPrefix("/files/") && ["GET", "HEAD"].contains(request.method) { return download(request) }
        return .text("Not found", status: 404)
    }

    private struct APIStatus: Codable {
        let name: String
        let status: String
        let running: Bool
        let port: UInt16
        let files: Int
        let bonjour: Bool
        let urls: [String]
    }

    private struct APICommand: Codable { let command: String }
    private struct APICommandResult: Codable { let output: String }

    private func upload(_ request: HTTPRequest) -> HTTPResponse {
        guard let rawName = request.query["name"], let name = safeName(rawName), !request.body.isEmpty else { return .text("Use POST /files/upload?name=filename", status: 400) }
        do {
            try request.body.write(to: filesURL.appendingPathComponent(name), options: .atomic)
            refreshFiles(); return .json(["saved": name, "bytes": String(request.body.count)])
        } catch { return .text("Write failed", status: 500) }
    }

    private func download(_ request: HTTPRequest) -> HTTPResponse {
        let raw = String(request.path.dropFirst("/files/".count)).removingPercentEncoding ?? ""
        guard let name = safeName(raw) else { return .text("Invalid filename", status: 400) }
        let url = filesURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return .text("Not found", status: 404) }
        return HTTPResponse(headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: ""))\""], body: data)
    }

    private func safeName(_ value: String) -> String? {
        let name = URL(fileURLWithPath: value).lastPathComponent
        guard !name.isEmpty,
              name != ".", name != "..",
              !value.contains("/"), !value.contains("\\"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }

    private func fileIndexHTML() -> String {
        let rows = files.map { file in
            let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
            return "<li><a href=\"/files/\(encoded)\">\(Self.escape(file.name))</a> <small>\(file.bytes) bytes</small></li>"
        }.joined()
        return """
        <!doctype html><meta name="viewport" content="width=device-width"><title>ServerPad Files</title>
        <style>body{font:16px system-ui;max-width:720px;margin:3rem auto;padding:1rem;background:#0b1220;color:#e8eef8}a{color:#68b5ff}li{padding:.6rem}button{padding:.55rem .8rem}</style>
        <h1>共有ファイル</h1>
        <p><input id="file" type="file"> <button onclick="upload()">アップロード</button></p>
        <p id="message"></p><ul>\(rows)</ul><p><a href="/">戻る</a></p>
        <script>
        async function upload(){
          const input=document.getElementById('file'), message=document.getElementById('message');
          if(!input.files.length){message.textContent='ファイルを選択してください';return;}
          const file=input.files[0]; message.textContent='アップロード中…';
          const response=await fetch('/files/upload?name='+encodeURIComponent(file.name),{method:'POST',body:file});
          message.textContent=response.ok?'完了しました':'失敗しました';
          if(response.ok) location.reload();
        }
        </script>
        """
    }

    private func record(_ message: String) {
        logs.insert(ServerLog(date: Date(), message: message), at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    private func saveSettings() {
        let snapshot = SettingsSnapshot(port: port, serverName: serverName, maxRequestMiB: maxRequestMiB, autoStart: autoStart, enabledPluginIDs: plugins.filter(\.isEnabled).map(\.id))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        settings.set(data, forKey: settingsKey)
    }

    private struct SettingsSnapshot: Codable {
        let port: UInt16
        let serverName: String
        let maxRequestMiB: Int
        let autoStart: Bool
        let sshPort: UInt16
        let sshUsername: String
        let sshPassword: String
        let enabledPluginIDs: [String]
    }

    private static let defaultPlugins = [
        ServerPlugin(id: "bonjour", name: "Bonjour公開", summary: "同じネットワーク上でサービスを見つけやすくする", isEnabled: false),
        ServerPlugin(id: "pin-auth", name: "PIN認証", summary: "管理画面への簡易認証を追加する", isEnabled: false),
        ServerPlugin(id: "zip", name: "ZIP操作", summary: "共有ファイルをZIPでまとめる", isEnabled: false),
        ServerPlugin(id: "ssh", name: "SSH管理コンソール", summary: "LAN内SSHからServerPad管理コマンドを実行する", isEnabled: false)
    ]

    private static let commandHelp = """
    help                 コマンド一覧
    status               サーバー状態
    start / stop         起動・停止
    restart              再起動
    port 8080            ポート変更（停止中のみ）
    name ServerPad       サーバー名変更
    url                  自己アクセス・LAN URL
    files                共有ファイル一覧
    delete FILE          共有ファイル削除
    plugins              プラグイン一覧
    plugin ID on|off     プラグイン切替
    config               現在の構成JSON
    curl                 アップロード用curl例
    ssh                  SSH状態・接続情報
    ssh start|stop       SSH起動・停止
    ssh password         SSH認証情報
    """

    private func startSSH() async {
        guard sshEnabled, sshServer?.isRunning != true else { return }
        let service = SSHServer()
        do {
            try await service.start(port: sshPort, username: sshUsername, password: sshPassword) { [weak self] command in
                guard let self else { return "ServerPad unavailable" }
                return await self.executeCommand(command)
            }
            sshServer = service
            record("SSH管理サーバーをポート \(sshPort) で開始")
        } catch {
            record("SSH起動失敗: \(error.localizedDescription)")
        }
    }

    private func stopSSH() async {
        guard let service = sshServer else { return }
        await service.stop()
        sshServer = nil
        record("SSH管理サーバーを停止")
    }

    private static func generatePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<16).compactMap { _ in alphabet.randomElement() })
    }

    private static func addresses() -> [String] {
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var address = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&address, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return Array(Set(result)).sorted()
    }

    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    private static let homeHTML = """
    <!doctype html><meta name="viewport" content="width=device-width"><title>ServerPad</title>
    <style>body{font:17px system-ui;max-width:720px;margin:4rem auto;padding:1rem;background:#07101f;color:#edf4ff}.card{padding:1.4rem;border:1px solid #263b59;border-radius:18px;background:#101c30}a{color:#71bdff}code{color:#7ee7bd}</style>
    <div class="card"><h1>ServerPad</h1><p>iPad HTTP server is running.</p><p><a href="/files">共有ファイル</a> · <a href="/api/status">API status</a> · <a href="/api/files">API files</a></p><p><code>POST /files/upload?name=example.txt</code></p></div>
    """
}
