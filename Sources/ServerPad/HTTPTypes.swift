import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<marker.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = marker.upperBound
        guard data.count >= bodyStart + expected else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + expected))
        let components = URLComponents(string: parts[1])
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return HTTPRequest(method: parts[0], target: parts[1], path: components?.path ?? parts[1], query: query, headers: headers, body: body)
    }

    static func expectedSize(_ data: Data) -> Int? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<marker.lowerBound], encoding: .utf8) else { return nil }
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].lowercased() == "content-length" { length = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return marker.upperBound + length
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, reason: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.reason = reason; self.headers = headers; self.body = body
    }

    public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, reason: status == 200 ? "OK" : "Error", headers: ["Content-Type": contentType], body: Data(text.utf8))
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: status == 200 ? "OK" : "Error", headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    func encoded(headOnly: Bool = false) -> Data {
        var all = headers
        all["Content-Length"] = "\(body.count)"
        all["Connection"] = "close"
        all["Server"] = "ServerPad/1.0"
        let head = "HTTP/1.1 \(status) \(reason)\r\n" + all.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
        var output = Data(head.utf8)
        if !headOnly { output.append(body) }
        return output
    }
}

