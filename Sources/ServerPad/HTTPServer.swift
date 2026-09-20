import Foundation
import Network

public actor HTTPServer {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ServerPad.HTTP")
    private let handler: Handler
    private let maximumRequestBytes = 25 * 1024 * 1024

    public init(handler: @escaping Handler) { self.handler = handler }

    public func start(port: UInt16) async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            newListener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                case .cancelled: resumed = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            newListener.start(queue: queue)
        }
        listener = newListener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var combined = buffer
            if let chunk { combined.append(chunk) }
            if combined.count > self.maximumRequestBytes { self.send(.text("Request too large", status: 413), to: connection); return }
            if let expected = HTTPRequest.expectedSize(combined), combined.count >= expected, let request = HTTPRequest.parse(combined) {
                Task { self.send(await self.handler(request), to: connection, headOnly: request.method == "HEAD") }
            } else if complete || error != nil {
                self.send(.text("Bad request", status: 400), to: connection)
            } else {
                self.receive(connection, buffer: combined)
            }
        }
    }

    private nonisolated func send(_ response: HTTPResponse, to connection: NWConnection, headOnly: Bool = false) {
        connection.send(content: response.encoded(headOnly: headOnly), completion: .contentProcessed { _ in connection.cancel() })
    }
}

