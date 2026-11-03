import CryptoKit
import Foundation
import NIOCore
import NIOPosix

/// A key both ends of a TCP display-host connection hold. TCP carries no peer credentials, so the key is what
/// admits a peer: each side proves it has the key over fresh nonces before any message passes.
public struct DisplayHostSecret: Sendable, Hashable {
    let key: Data

    /// At least 32 bytes.
    public init?(_ key: Data) {
        guard key.count >= 32 else { return nil }
        self.key = key
    }

    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data)
    }

    public static func random() -> DisplayHostSecret {
        DisplayHostSecret(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })!
    }

    public var base64: String { key.base64EncodedString() }

    func proof(_ role: String, _ serverNonce: Data, _ clientNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + serverNonce + clientNonce, using: SymmetricKey(data: key)))
    }
}

/// Display-host connections over TCP, for a host on another machine or inside a VM, length-prefix framed like the
/// Unix socket. Both ends prove they hold a ``DisplayHostSecret`` before any message passes. Traffic isn't
/// encrypted, so use it on a network only the two ends share, such as a VM's host-only network, or in a tunnel.
public enum DisplayHostTCP {
    static let nonceBytes = 32
    static let handshakeTimeout: Duration = .seconds(10)

    public static func listen(host: String = "127.0.0.1", port: Int, secret: DisplayHostSecret) async throws -> DisplayHostTCPListener {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        return DisplayHostTCPListener(server: server, secret: secret)
    }

    /// Connects and proves the secret both ways; throws ``DisplayHostError/peerRejected`` when the host doesn't.
    public static func connect(host: String, port: Int, secret: DisplayHostSecret) async throws -> any DisplayHostConnection {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let connection = try await DisplayHostSocketConnection.open(channel)
        return try await authenticate(connection) { connection, messages in
            guard let serverNonce = try await messages.next(), serverNonce.count == nonceBytes else { throw DisplayHostError.peerRejected }
            let clientNonce = randomNonce()
            try await connection.send(clientNonce + secret.proof("client", serverNonce, clientNonce))
            guard let proof = try await messages.next(), proof == secret.proof("server", serverNonce, clientNonce) else {
                throw DisplayHostError.peerRejected
            }
        }
    }

    /// The server's side of the handshake, for an accepted connection.
    static func accept(_ connection: DisplayHostSocketConnection, secret: DisplayHostSecret) async throws -> any DisplayHostConnection {
        try await authenticate(connection) { connection, messages in
            let serverNonce = randomNonce()
            try await connection.send(serverNonce)
            guard let reply = try await messages.next(), reply.count == nonceBytes + 32 else { throw DisplayHostError.peerRejected }
            let clientNonce = reply.prefix(nonceBytes)
            guard reply.suffix(32) == secret.proof("client", serverNonce, clientNonce) else { throw DisplayHostError.peerRejected }
            try await connection.send(secret.proof("server", serverNonce, clientNonce))
        }
    }

    private static func authenticate(
        _ connection: DisplayHostSocketConnection,
        handshake: @escaping @Sendable (DisplayHostSocketConnection, DisplayHostHandshakeReader) async throws -> Void
    ) async throws -> any DisplayHostConnection {
        let reader = DisplayHostHandshakeReader(connection.inbound)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await handshake(connection, reader) }
                group.addTask {
                    try await Task.sleep(for: handshakeTimeout)
                    throw DisplayHostError.peerRejected
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await connection.close()
            throw error is DisplayHostError ? error : DisplayHostError.peerRejected
        }
        return AuthenticatedDisplayHostConnection(connection: connection, reader: reader)
    }

    private static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// Reads the handshake's frames, then hands the rest of the stream on, so one task iterates it.
actor DisplayHostHandshakeReader {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    nonisolated let rest: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(_ stream: AsyncThrowingStream<Data, any Error>) {
        iterator = stream.makeAsyncIterator()
        (rest, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    }

    func next() async throws -> Data? {
        // Called from one task at a time, so the copy can't race another reader.
        var current = iterator
        defer { iterator = current }
        return try await current.next(isolation: self)
    }

    /// Forwards everything after the handshake to `rest` until the connection closes.
    nonisolated func forward() -> Task<Void, Never> {
        Task { await self.forwardAll() }
    }

    private func forwardAll() async {
        do {
            while let message = try await next() { continuation.yield(message) }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

final class AuthenticatedDisplayHostConnection: DisplayHostConnection {
    let peer = DisplayHostPeer()
    let inbound: AsyncThrowingStream<Data, any Error>
    private let connection: DisplayHostSocketConnection
    private let forwarding: Task<Void, Never>

    init(connection: DisplayHostSocketConnection, reader: DisplayHostHandshakeReader) {
        self.connection = connection
        inbound = reader.rest
        forwarding = reader.forward()
    }

    func send(_ message: Data) async throws {
        try await connection.send(message)
    }

    func close() async {
        await connection.close()
        await forwarding.value
    }
}

public final class DisplayHostTCPListener: DisplayHostListener {
    public let port: Int
    public let connections: AsyncThrowingStream<any DisplayHostConnection, any Error>
    private let acceptor: Task<Void, Never>
    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>

    init(server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>, secret: DisplayHostSecret) {
        self.server = server
        port = server.channel.localAddress?.port ?? 0
        let (connections, continuation) = AsyncThrowingStream.makeStream(of: (any DisplayHostConnection).self, throwing: (any Error).self)
        self.connections = connections
        acceptor = Task {
            do {
                try await server.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await child in inbound {
                            // Each handshake runs on its own, so a peer that never answers holds up no one else.
                            group.addTask {
                                guard let opened = try? await DisplayHostSocketConnection.open(child),
                                      let connection = try? await DisplayHostTCP.accept(opened, secret: secret) else { return }
                                continuation.yield(connection)
                            }
                        }
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
    }
}
