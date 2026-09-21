import Foundation

actor JMAAPIService {
    private struct CachedResponse {
        let data: Data
        let contentType: String
        let date: Date
    }

    private var cache: [String: CachedResponse] = [:]
    private let baseURL = URL(string: "https://api.wolfx.jp")!
    static let endpointNames = [
        "jma_eew.json",
        "jma_earthquake.json",
        "jma_tsunami.json",
        "jma_warning.json",
        "jma_forecast.json",
        "jma_volcano.json",
        "jma_amedas.json"
    ]
    private let allowedEndpoints: Set<String> = Set(Self.endpointNames)

    func response(for requestPath: String) async -> HTTPResponse {
        let raw = String(requestPath.dropFirst("/api/jma/".count))
        let endpoint = raw.split(separator: "?").first.map(String.init) ?? raw
        guard allowedEndpoints.contains(endpoint) else {
            return .json(["error": "unsupported_endpoint", "available": allowedEndpoints.sorted()], status: 404)
        }

        if let cached = cache[endpoint], Date().timeIntervalSince(cached.date) < 1 {
            return HTTPResponse(
                headers: [
                    "Content-Type": cached.contentType,
                    "Access-Control-Allow-Origin": "*",
                    "X-ServerPad-Cache": "hit"
                ],
                body: cached.data
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent(endpoint))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .json(["error": "upstream_unavailable"], status: 502)
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            cache[endpoint] = CachedResponse(data: data, contentType: contentType, date: Date())
            return HTTPResponse(
                headers: [
                    "Content-Type": contentType,
                    "Access-Control-Allow-Origin": "*",
                    "X-ServerPad-Source": "Wolfx JMA adapter",
                    "X-ServerPad-Cache": "miss"
                ],
                body: data
            )
        } catch {
            return .json(["error": "upstream_request_failed"], status: 502)
        }
    }

    nonisolated var endpointList: [String] {
        Self.endpointNames
    }
}
