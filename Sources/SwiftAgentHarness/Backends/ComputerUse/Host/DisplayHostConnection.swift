import Foundation

/// Who is on the other end of a connection, as far as the transport can tell.
public struct DisplayHostPeer: Sendable, Hashable {
    public var processID: Int32?
    public var userID: UInt32?
    /// The kernel audit token's eight words, for code-signature checks. Darwin Unix sockets provide it.
    public var auditToken: [UInt32]?

    public init(processID: Int32? = nil, userID: UInt32? = nil, auditToken: [UInt32]? = nil) {
        self.processID = processID
        self.userID = userID
        self.auditToken = auditToken
    }
}

/// Decides whether a transport keeps a connection with a peer.
public struct DisplayHostPeerRequirement: Sendable {
    private let check: @Sendable (DisplayHostPeer) async -> Bool

    public init(_ check: @escaping @Sendable (DisplayHostPeer) async -> Bool) {
        self.check = check
    }

    public func accepts(_ peer: DisplayHostPeer) async -> Bool {
        await check(peer)
    }

    /// Peers running as this process's user.
    public static var sameUser: Self {
        let uid = getuid()
        return Self { $0.userID == uid }
    }

    /// Peers every one of `requirements` accepts.
    public static func all(of requirements: Self...) -> Self {
        Self { peer in
            for requirement in requirements {
                guard await requirement.accepts(peer) else { return false }
            }
            return true
        }
    }
}

/// A message connection between a harness and a display host. Each message is one encoded
/// ``DisplayHostMessage``; the transport keeps message boundaries.
public protocol DisplayHostConnection: Sendable {
    var peer: DisplayHostPeer { get }
    /// Messages from the peer, finishing when the connection closes. Iterate it from one task only.
    var inbound: AsyncThrowingStream<Data, any Error> { get }
    /// Concurrent sends are delivered whole, in some order.
    func send(_ message: Data) async throws
    /// Idempotent. Ends `inbound` on both sides.
    func close() async
}

/// Accepted connections, already past the transport's peer requirement.
public protocol DisplayHostListener: Sendable {
    var connections: AsyncThrowingStream<any DisplayHostConnection, any Error> { get }
    func close() async
}

/// Both ends of a connection inside one process, for hosting a target in-process behind the protocol and for
/// tests.
public final class InMemoryDisplayHostConnection: DisplayHostConnection {
    public let peer: DisplayHostPeer
    public let inbound: AsyncThrowingStream<Data, any Error>
    private let own: AsyncThrowingStream<Data, any Error>.Continuation
    private let remote: AsyncThrowingStream<Data, any Error>.Continuation

    private init(
        inbound: AsyncThrowingStream<Data, any Error>,
        own: AsyncThrowingStream<Data, any Error>.Continuation,
        remote: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.peer = DisplayHostPeer(
            processID: ProcessInfo.processInfo.processIdentifier,
            userID: getuid()
        )
        self.inbound = inbound
        self.own = own
        self.remote = remote
    }

    /// A connected pair: what one sends, the other receives.
    public static func pair() -> (InMemoryDisplayHostConnection, InMemoryDisplayHostConnection) {
        let (first, firstContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let (second, secondContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        return (
            InMemoryDisplayHostConnection(inbound: first, own: firstContinuation, remote: secondContinuation),
            InMemoryDisplayHostConnection(inbound: second, own: secondContinuation, remote: firstContinuation)
        )
    }

    public func send(_ message: Data) async throws {
        guard message.count <= DisplayHostProtocol.maxMessageBytes else {
            throw DisplayHostError.frameTooLarge(message.count)
        }
        if case .terminated = remote.yield(message) { throw DisplayHostError.connectionClosed }
    }

    public func close() async {
        own.finish()
        remote.finish()
    }
}

/// Length-prefixed framing for byte-stream transports: a big-endian `UInt32` length, then the message.
public enum DisplayHostFraming {
    public static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(message)
        return framed
    }
}

public struct DisplayHostFrameDecoder: Sendable {
    public let maxFrameBytes: Int
    private var buffer = Data()

    public init(maxFrameBytes: Int = DisplayHostProtocol.maxMessageBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// The frames `bytes` completes. Throws, without buffering, on a length over the limit.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxFrameBytes else {
                buffer.removeAll()
                throw DisplayHostError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }
}
