import Foundation
import NIOCore
import NIOPosix

/// Resolves host names for the network proxy. The proxy connects to the addresses returned here, never to the name,
/// so the address the policy checked is the one connected to.
public protocol BrowserNetworkResolving: Sendable {
    func resolve(_ host: String) async throws -> [BrowserNetworkAddress]
}

public struct SystemBrowserNetworkResolver: BrowserNetworkResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [BrowserNetworkAddress] {
        try await Task.detached { try Self.lookup(host) }.value
    }

    struct LookupError: Error, CustomStringConvertible {
        var code: Int32
        var description: String { String(cString: gai_strerror(code)) }
    }

    private static func lookup(_ host: String) throws -> [BrowserNetworkAddress] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &list)
        guard code == 0 else { throw LookupError(code: code) }
        defer { freeaddrinfo(list) }
        var addresses: [BrowserNetworkAddress] = []
        var next = list
        while let info = next {
            if let raw = info.pointee.ai_addr {
                switch info.pointee.ai_family {
                case AF_INET:
                    raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        addresses.append(.v4(withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }))
                    }
                case AF_INET6:
                    raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        addresses.append(.v6(withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }))
                    }
                default:
                    break
                }
            }
            next = info.pointee.ai_next
        }
        var seen = Set<BrowserNetworkAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}

/// A connection the proxy refused.
public struct BrowserNetworkDenial: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var reason: String
    public var at: Date
}

/// The SOCKS5 wire format, server side, for the subset a browser uses: no authentication and CONNECT.
enum SOCKS5 {
    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case notAllowed = 0x02
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    struct Request: Equatable {
        var host: String
        var port: Int
    }

    enum Parsed<Value: Equatable>: Equatable {
        case needMore
        case parsed(Value, consumed: Int)
        case invalid(Reply?)
    }

    static func greeting(_ bytes: [UInt8]) -> Parsed<[UInt8]> {
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == 5 else { return .invalid(nil) }
        let count = Int(bytes[1])
        guard bytes.count >= 2 + count else { return .needMore }
        return .parsed(Array(bytes[2..<(2 + count)]), consumed: 2 + count)
    }

    static func request(_ bytes: [UInt8]) -> Parsed<Request> {
        guard bytes.count >= 5 else { return .needMore }
        guard bytes[0] == 5, bytes[2] == 0 else { return .invalid(.generalFailure) }
        guard bytes[1] == 1 else { return .invalid(.commandNotSupported) }
        let host: String
        let start: Int
        switch bytes[3] {
        case 1:
            guard bytes.count >= 4 + 4 + 2 else { return .needMore }
            host = BrowserNetworkAddress.v4(Array(bytes[4..<8])).description
            start = 8
        case 3:
            let length = Int(bytes[4])
            guard length > 0 else { return .invalid(.generalFailure) }
            guard bytes.count >= 5 + length + 2 else { return .needMore }
            host = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
            start = 5 + length
        case 4:
            guard bytes.count >= 4 + 16 + 2 else { return .needMore }
            host = BrowserNetworkAddress.v6(Array(bytes[4..<20])).description
            start = 20
        default:
            return .invalid(.addressTypeNotSupported)
        }
        let port = Int(bytes[start]) << 8 | Int(bytes[start + 1])
        return .parsed(Request(host: host, port: port), consumed: start + 2)
    }

    static func reply(_ code: Reply) -> [UInt8] {
        [5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]
    }
}

/// A loopback SOCKS5 proxy that is a browser target's only way to the network. Every connection, including each
/// redirect hop and every subresource, is checked against the policy by name and again by resolved address, and
/// connected to the address that was checked. Anything it can't check is refused.
public actor BrowserNetworkProxy {
    public nonisolated let policy: BrowserNetworkPolicy
    private let resolver: any BrowserNetworkResolving
    private let connectTimeout: TimeAmount
    private var server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>?
    private var acceptor: Task<Void, Never>?
    private let log: DenialLog

    public init(
        policy: BrowserNetworkPolicy,
        resolver: any BrowserNetworkResolving = SystemBrowserNetworkResolver(),
        connectTimeout: Duration = .seconds(10),
        maxDenials: Int = 50
    ) {
        self.policy = policy
        self.resolver = resolver
        self.connectTimeout = .nanoseconds(Int64(connectTimeout.timeInterval * 1e9))
        self.log = DenialLog(capacity: maxDenials)
    }

    /// Starts listening on an ephemeral loopback port, and returns it.
    public func start() async throws -> Int {
        if let port = server?.channel.localAddress?.port { return port }
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        self.server = server
        let policy = policy
        let resolver = resolver
        let timeout = connectTimeout
        let log = log
        acceptor = Task {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await client in inbound {
                        group.addTask {
                            await Self.serve(client, policy: policy, resolver: resolver, timeout: timeout) { denial in
                                await log.record(denial)
                            }
                        }
                    }
                }
            }
        }
        guard let port = server.channel.localAddress?.port else { throw DisplayTargetError.driverFailure("the network proxy has no port") }
        return port
    }

    public func stop() async {
        try? await server?.channel.close()
        acceptor?.cancel()
        await acceptor?.value
        server = nil
        acceptor = nil
    }

    /// Recent refusals, oldest first.
    public var denials: [BrowserNetworkDenial] {
        get async { await log.recent }
    }

    public func denials(since date: Date) async -> [BrowserNetworkDenial] {
        await log.recent.filter { $0.at >= date }
    }

    private actor DenialLog {
        let capacity: Int
        private(set) var recent: [BrowserNetworkDenial] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        func record(_ denial: BrowserNetworkDenial) {
            recent.append(denial)
            if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        }
    }

    private static func serve(
        _ client: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        policy: BrowserNetworkPolicy,
        resolver: any BrowserNetworkResolving,
        timeout: TimeAmount,
        record: @escaping @Sendable (BrowserNetworkDenial) async -> Void
    ) async {
        try? await client.executeThenClose { inbound, outbound in
            var reader = inbound.makeAsyncIterator()
            var pending: [UInt8] = []

            func read<Value>(_ parse: ([UInt8]) -> SOCKS5.Parsed<Value>) async throws -> (Value?, SOCKS5.Reply?) {
                while true {
                    switch parse(pending) {
                    case .parsed(let value, let consumed):
                        pending.removeFirst(consumed)
                        return (value, nil)
                    case .invalid(let reply):
                        return (nil, reply)
                    case .needMore:
                        guard pending.count < 600, let buffer = try await reader.next() else { return (nil, nil) }
                        pending.append(contentsOf: buffer.readableBytesView)
                    }
                }
            }

            guard case (let methods?, _) = try await read(SOCKS5.greeting) else { return }
            guard methods.contains(0) else {
                try await outbound.write(ByteBuffer(bytes: [5, 0xff]))
                return
            }
            try await outbound.write(ByteBuffer(bytes: [5, 0]))

            let (parsed, failure) = try await read(SOCKS5.request)
            guard let request = parsed else {
                if let failure { try await outbound.write(ByteBuffer(bytes: SOCKS5.reply(failure))) }
                return
            }

            func refuse(_ reason: String, _ reply: SOCKS5.Reply = .notAllowed) async throws {
                await record(BrowserNetworkDenial(host: request.host, port: request.port, reason: reason, at: Date()))
                try await outbound.write(ByteBuffer(bytes: SOCKS5.reply(reply)))
            }

            if let reason = policy.evaluate(host: request.host).denialReason { return try await refuse(reason) }
            let addresses: [BrowserNetworkAddress]
            if let literal = BrowserNetworkAddress(request.host) {
                addresses = [literal]
            } else {
                do {
                    addresses = try await resolver.resolve(request.host)
                } catch {
                    return try await refuse("\(request.host) did not resolve: \(error)", .hostUnreachable)
                }
            }
            if let reason = policy.evaluate(addresses: addresses, host: request.host).denialReason {
                return try await refuse(reason)
            }

            let upstream: NIOAsyncChannel<ByteBuffer, ByteBuffer>
            do {
                let address = try SocketAddress(ipAddress: addresses[0].description, port: request.port)
                upstream = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(timeout)
                    .connect(to: address) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                        }
                    }
            } catch {
                try await outbound.write(ByteBuffer(bytes: SOCKS5.reply(.connectionRefused)))
                return
            }
            let clientChannel = client.channel
            // The upstream channel must be opened before anything else can throw, or NIO traps on its unused writer.
            try await upstream.executeThenClose { upstreamInbound, upstreamOutbound in
                try await outbound.write(ByteBuffer(bytes: SOCKS5.reply(.succeeded)))
                if !pending.isEmpty { try await upstreamOutbound.write(ByteBuffer(bytes: pending)) }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        defer { clientChannel.close(promise: nil) }
                        for try await buffer in upstreamInbound { try await outbound.write(buffer) }
                    }
                    // Whichever side closes first ends the tunnel.
                    while let buffer = try await reader.next() { try await upstreamOutbound.write(buffer) }
                    group.cancelAll()
                }
            }
        }
    }
}
