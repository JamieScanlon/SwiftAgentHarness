import Foundation
import NIOCore
import NIOPosix

/// Display-host connections over a Unix-domain socket, length-prefix framed. The socket file is created
/// owner-only, and both ends check the other's ``DisplayHostPeer`` against a requirement, by default that it
/// runs as the same user.
public enum DisplayHostSocket {
    /// Listens at `path`, replacing a stale socket file there.
    public static func listen(
        path: String,
        peers: DisplayHostPeerRequirement = .sameUser
    ) async throws -> DisplayHostSocketListener {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            try? await server.channel.close()
            throw DisplayHostError.transportFailure("could not make \(path) owner-only: errno \(code)")
        }
        return DisplayHostSocketListener(server: server, path: path, peers: peers)
    }

    /// Connects to a host listening at `path`; throws ``DisplayHostError/peerRejected`` when `peers` refuses it.
    public static func connect(
        path: String,
        peers: DisplayHostPeerRequirement = .sameUser
    ) async throws -> DisplayHostSocketConnection {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(unixDomainSocketPath: path) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let connection = try await DisplayHostSocketConnection.open(channel)
        guard await peers.accepts(connection.peer) else {
            await connection.close()
            throw DisplayHostError.peerRejected
        }
        return connection
    }

    static func peer(of channel: any Channel) async -> DisplayHostPeer {
        guard let provider = channel as? any SocketOptionProvider else { return DisplayHostPeer() }
        let level = SocketOptionLevel(SOL_LOCAL)
        let pid: pid_t? = try? await provider.unsafeGetSocketOption(level: level, name: SocketOptionName(LOCAL_PEERPID)).get()
        let credentials: xucred? = try? await provider.unsafeGetSocketOption(level: level, name: SocketOptionName(LOCAL_PEERCRED)).get()
        let token: audit_token_t? = try? await provider.unsafeGetSocketOption(level: level, name: SocketOptionName(LOCAL_PEERTOKEN)).get()
        return DisplayHostPeer(
            processID: pid,
            userID: credentials.map(\.cr_uid),
            auditToken: token.map { token in
                withUnsafeBytes(of: token.val) { Array($0.bindMemory(to: UInt32.self)) }
            }
        )
    }
}

public final class DisplayHostSocketListener: DisplayHostListener {
    public let path: String
    public let connections: AsyncThrowingStream<any DisplayHostConnection, any Error>
    private let acceptor: Task<Void, Never>
    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>

    init(server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>, path: String, peers: DisplayHostPeerRequirement) {
        self.server = server
        self.path = path
        let (connections, continuation) = AsyncThrowingStream.makeStream(of: (any DisplayHostConnection).self, throwing: (any Error).self)
        self.connections = connections
        acceptor = Task {
            do {
                try await server.executeThenClose { inbound in
                    for try await child in inbound {
                        guard let connection = try? await DisplayHostSocketConnection.open(child) else { continue }
                        guard await peers.accepts(connection.peer) else {
                            await connection.close()
                            continue
                        }
                        continuation.yield(connection)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func close() async {
        try? await server.channel.close()
        await acceptor.value
        unlink(path)
    }
}

public final class DisplayHostSocketConnection: DisplayHostConnection {
    public let peer: DisplayHostPeer
    public let inbound: AsyncThrowingStream<Data, any Error>
    private let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let channel: any Channel
    private let pump: Task<Void, Never>

    private init(peer: DisplayHostPeer, inbound: AsyncThrowingStream<Data, any Error>, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>, channel: any Channel, pump: Task<Void, Never>) {
        self.peer = peer
        self.inbound = inbound
        self.writer = writer
        self.channel = channel
        self.pump = pump
    }

    static func open(_ asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws -> DisplayHostSocketConnection {
        let peer = await DisplayHostSocket.peer(of: asyncChannel.channel)
        let (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let (ready, readyContinuation) = AsyncStream.makeStream(of: NIOAsyncChannelOutboundWriter<ByteBuffer>.self)
        // The writer is only valid inside executeThenClose, so the pump owns the channel for its whole life.
        let pump = Task {
            do {
                try await asyncChannel.executeThenClose { input, writer in
                    readyContinuation.yield(writer)
                    readyContinuation.finish()
                    var decoder = DisplayHostFrameDecoder()
                    for try await buffer in input {
                        for frame in try decoder.append(Data(buffer.readableBytesView)) {
                            continuation.yield(frame)
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            readyContinuation.finish()
        }
        var readiness = ready.makeAsyncIterator()
        guard let writer = await readiness.next() else { throw DisplayHostError.connectionClosed }
        return DisplayHostSocketConnection(peer: peer, inbound: inbound, writer: writer, channel: asyncChannel.channel, pump: pump)
    }

    public func send(_ message: Data) async throws {
        guard message.count <= DisplayHostProtocol.maxMessageBytes else {
            throw DisplayHostError.frameTooLarge(message.count)
        }
        do {
            try await writer.write(ByteBuffer(bytes: DisplayHostFraming.frame(message)))
        } catch {
            throw DisplayHostError.connectionClosed
        }
    }

    public func close() async {
        try? await channel.close()
        await pump.value
    }
}
