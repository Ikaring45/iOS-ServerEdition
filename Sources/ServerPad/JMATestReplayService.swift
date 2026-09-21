import Foundation

struct JMAReplayStatus: Codable, Sendable {
    let enabled: Bool
    let playing: Bool
    let scenario: String
    let scenarioName: String
    let positionSeconds: Double
    let durationSeconds: Double
    let speed: Double
    let currentEvent: String?
    let currentEndpoint: String?
    let manualPayload: Bool
}

private struct JMAReplayEvent {
    let id: String
    let offset: Double
    let endpoint: String
    let payload: Data
}

private struct JMAReplayScenario {
    let id: String
    let name: String
    let events: [JMAReplayEvent]
    var duration: Double { events.map(\.offset).max() ?? 0 }
}

actor JMATestReplayService {
    private var enabled = false
    private var playing = false
    private var scenarioID = "demo-eew"
    private var position = 0.0
    private var speed = 1.0
    private var lastStartedAt: Date?
    private var manualPayloads: [String: Data] = [:]

    private let scenarios: [JMAReplayScenario] = [
        JMAReplayScenario(id: "demo-eew", name: "緊急地震速報（段階更新）", events: [
            JMAReplayEvent(id: "eew-1", offset: 0, endpoint: "jma_eew.json", payload: Self.json(#"{"Title":"緊急地震速報（予報）","CodeType":"11","Issue":"2026/07/30 00:50:10","EventID":"20260730005001","Serial":1,"AnnouncedTime":"2026/07/30 00:50:10","OriginTime":"2026/07/30 00:50:01","Hypocenter":"新潟県下越","Latitude":37.8,"Longitude":139.2,"Magunitude":4.8,"Magnitude":4.8,"Depth":20,"MaxIntensity":"3","isFinal":false,"arrive":false}"#)),
            JMAReplayEvent(id: "eew-2", offset: 8, endpoint: "jma_eew.json", payload: Self.json(#"{"Title":"緊急地震速報（予報）","CodeType":"11","Issue":"2026/07/30 00:50:18","EventID":"20260730005001","Serial":2,"AnnouncedTime":"2026/07/30 00:50:18","OriginTime":"2026/07/30 00:50:01","Hypocenter":"新潟県下越","Latitude":37.8,"Longitude":139.2,"Magunitude":5.2,"Magnitude":5.2,"Depth":20,"MaxIntensity":"4","isFinal":false,"arrive":true}"#)),
            JMAReplayEvent(id: "eew-3", offset: 18, endpoint: "jma_eew.json", payload: Self.json(#"{"Title":"緊急地震速報（最終）","CodeType":"11","Issue":"2026/07/30 00:50:28","EventID":"20260730005001","Serial":3,"AnnouncedTime":"2026/07/30 00:50:28","OriginTime":"2026/07/30 00:50:01","Hypocenter":"新潟県下越","Latitude":37.8,"Longitude":139.2,"Magunitude":5.4,"Magnitude":5.4,"Depth":20,"MaxIntensity":"5弱","isFinal":true,"arrive":true}"#))
        ])
    ]

    func status() -> JMAReplayStatus {
        let current = currentEvent()
        return JMAReplayStatus(enabled: enabled, playing: playing, scenario: scenarioID, scenarioName: selectedScenario().name, positionSeconds: elapsed(), durationSeconds: selectedScenario().duration, speed: speed, currentEvent: current?.id, currentEndpoint: current?.endpoint, manualPayload: !manualPayloads.isEmpty)
    }

    func scenariosJSON() -> HTTPResponse {
        let values = scenarios.map { ["id": $0.id, "name": $0.name, "durationSeconds": String($0.duration), "events": String($0.events.count)] }
        return .json(values)
    }

    func response(for requestPath: String) -> HTTPResponse {
        let raw = String(requestPath.dropFirst("/api/jma/".count))
        let endpoint = raw.split(separator: "?").first.map(String.init) ?? raw
        if let manual = manualPayloads[endpoint] {
            return HTTPResponse(headers: testHeaders(endpoint), body: manual)
        }
        guard enabled else { return .json(["error": "test_mode_disabled"], status: 409) }
        guard let event = currentEvent(for: endpoint) else {
            return .json(["test": true, "state": "waiting", "endpoint": endpoint, "scenario": scenarioID])
        }
        return HTTPResponse(headers: testHeaders(endpoint), body: event.payload)
    }

    func control(_ body: Data) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let action = object["action"] as? String else {
            return .json(["error": "action_required"], status: 400)
        }
        switch action.lowercased() {
        case "on", "enable":
            enabled = true
        case "off", "disable":
            enabled = false; playing = false; lastStartedAt = nil
        case "load":
            guard let id = object["scenario"] as? String, scenarios.contains(where: { $0.id == id }) else {
                return .json(["error": "unknown_scenario", "available": scenarios.map(\.id)], status: 400)
            }
            scenarioID = id; position = 0; playing = false; lastStartedAt = nil
        case "start", "play":
            enabled = true
            if elapsed() >= selectedScenario().duration { position = 0 }
            playing = true; lastStartedAt = Date()
        case "pause":
            position = elapsed(); playing = false; lastStartedAt = nil
        case "stop", "reset":
            position = 0; playing = false; lastStartedAt = nil
        case "seek":
            guard let seconds = object["seconds"] as? Double else { return .json(["error": "seconds_required"], status: 400) }
            position = max(0, min(seconds, selectedScenario().duration))
            if playing { lastStartedAt = Date() }
        case "speed":
            guard let value = object["speed"] as? Double, value > 0, value <= 100 else { return .json(["error": "speed_must_be_0_to_100"], status: 400) }
            position = elapsed(); speed = value
            if playing { lastStartedAt = Date() }
        case "emit":
            guard let endpoint = object["endpoint"] as? String, let payload = object["payload"], JMAAPIService.endpointNames.contains(endpoint), JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return .json(["error": "endpoint_and_json_payload_required"], status: 400)
            }
            manualPayloads[endpoint] = data; enabled = true
        case "clear":
            manualPayloads.removeAll()
        default:
            return .json(["error": "unknown_action"], status: 400)
        }
        return .json(status())
    }

    func command(_ args: [String]) -> String {
        guard let subcommand = args.first?.lowercased() else {
            return "test status | on | off | scenarios | load demo-eew | start | pause | stop | seek SECONDS | speed N | clear"
        }
        switch subcommand {
        case "status": return statusText()
        case "on": enabled = true; return statusText()
        case "off": enabled = false; playing = false; return statusText()
        case "scenarios": return scenarios.map { "\($0.id)\t\($0.name)\t\($0.duration)s" }.joined(separator: "\n")
        case "load":
            guard args.count > 1, scenarios.contains(where: { $0.id == args[1] }) else { return "使い方: test load demo-eew" }
            scenarioID = args[1]; position = 0; playing = false; return statusText()
        case "start": enabled = true; playing = true; lastStartedAt = Date(); return statusText()
        case "pause": position = elapsed(); playing = false; lastStartedAt = nil; return statusText()
        case "stop": position = 0; playing = false; lastStartedAt = nil; return statusText()
        case "seek":
            guard args.count > 1, let value = Double(args[1]) else { return "使い方: test seek 10" }
            position = max(0, min(value, selectedScenario().duration)); return statusText()
        case "speed":
            guard args.count > 1, let value = Double(args[1]), value > 0, value <= 100 else { return "使い方: test speed 10" }
            position = elapsed(); speed = value; if playing { lastStartedAt = Date() }; return statusText()
        case "clear": manualPayloads.removeAll(); return statusText()
        default: return "使い方: test status|on|off|scenarios|load|start|pause|stop|seek|speed|clear"
        }
    }

    private func selectedScenario() -> JMAReplayScenario { scenarios.first(where: { $0.id == scenarioID }) ?? scenarios[0] }

    private func elapsed() -> Double {
        guard playing, let start = lastStartedAt else { return position }
        let value = position + Date().timeIntervalSince(start) * speed
        if value >= selectedScenario().duration {
            playing = false; position = selectedScenario().duration; lastStartedAt = nil; return position
        }
        return value
    }

    private func currentEvent(for endpoint: String? = nil) -> JMAReplayEvent? {
        let time = elapsed()
        return selectedScenario().events.filter { $0.offset <= time && (endpoint == nil || $0.endpoint == endpoint) }.max { $0.offset < $1.offset }
    }

    private func statusText() -> String {
        let value = status()
        return "test=\(value.enabled ? "on" : "off") playing=\(value.playing) scenario=\(value.scenario) position=\(String(format: "%.1f", value.positionSeconds))s/\(String(format: "%.1f", value.durationSeconds))s speed=\(value.speed)x current=\(value.currentEvent ?? "-")"
    }

    private func testHeaders(_ endpoint: String) -> [String: String] {
        ["Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*", "X-ServerPad-Test-Mode": "true", "X-ServerPad-Test-Endpoint": endpoint, "X-ServerPad-Test-Scenario": scenarioID]
    }

    private static func json(_ text: String) -> Data { text.data(using: .utf8) ?? Data() }
}
