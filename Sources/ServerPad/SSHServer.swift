import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

public enum SSHServerError: Error {
    case notRunning
}

private final class SSHPasswordDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username,
              case .password(let passwordRequest) = request.request,
              passwordRequest.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private final class SSHSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let execute: @Sendable (String) async -> String
    private var input = ""
    private var didStartShell = false
    private var didExecute = false

    init(execute: @escaping @Sendable (String) async -> String) {
        self.execute = execute
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.ShellRequest:
            didStartShell = true
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            write("ServerPad SSH console\r\nType 'help' for commands.\r\n> ", to: context.channel)
        case let request as SSHChannelRequestEvent.ExecRequest:
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            run(request.command, on: context.channel, closeWhenDone: true)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard case .channel = packet.type, case .byteBuffer(var buffer) = packet.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        input.append(contentsOf: String(decoding: bytes, as: UTF8.self))
        while let newline = input.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let command = String(input[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            input.removeSubrange(...newline)
            guard didStartShell, !command.isEmpty else { continue }
            run(command, on: context.channel, closeWhenDone: false)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    private func run(_ command: String, on channel: Channel, closeWhenDone: Bool) {
        Task {
            let output = await execute(command)
            channel.eventLoop.execute {
                self.write(output + (closeWhenDone ? "" : "\r\n> "), to: channel)
                if closeWhenDone {
                    channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                }
            }
        }
    }

    private func write(_ text: String, to channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }
}

@MainActor
public final class SSHServer: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "停止中"
    @Published public private(set) var boundPort: UInt16 = 2222

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init() {}

    public func start(
        port: UInt16,
        username: String,
        password: String,
        execute: @escaping @Sendable (String) async -> String
    ) async throws {
        guard !isRunning else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let auth = SSHPasswordDelegate(username: username, password: password)

        func initializeChild(_ channel: Channel, _ type: SSHChannelType) -> EventLoopFuture<Void> {
            guard type == .session else {
                return channel.eventLoop.makeFailedFuture(SSHServerError.notRunning)
            }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    SSHSessionHandler(execute: execute)
                )
            }
        }

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .server(.init(
                                hostKeys: [hostKey],
                                userAuthDelegate: auth
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: initializeChild(_:_:)
                        )
                    ])
                }
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        do {
            let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.group = group
            self.channel = channel
            self.boundPort = port
            self.isRunning = true
            self.status = "稼働中"
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func stop() async {
        try? await channel?.close()
        channel = nil
        if let group {
            try? group.syncShutdownGracefully()
        }
        self.group = nil
        isRunning = false
        status = "停止中"
    }
}
