import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwiftAgentHarness

@Suite("Browser network proxy")
struct BrowserNetworkProxyTests {
    private actor ScriptedResolver: BrowserNetworkResolving {
        let answers: [String: [String]]
        private(set) var asked: [String] = []

        init(_ answers: [String: [String]]) {
            self.answers = answers
        }

        func resolve(_ host: String) async throws -> [BrowserNetworkAddress] {
            asked.append(host)
            guard let answer = answers[host] else { throw SystemBrowserNetworkResolver.LookupError(code: EAI_NONAME) }
            return answer.compactMap(BrowserNetworkAddress.init)
        }
    }

    private struct EchoServer {
        var port: Int
        var channel: any Channel
        var task: Task<Void, Never>

        func stop() async {
            try? await channel.close()
            await task.value
        }
    }

    /// A loopback server that echoes what it reads.
    private static func echoServer() async throws -> EchoServer {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
            }
        let task = Task<Void, Never> {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in inbound {
                        group.addTask {
                            try? await connection.executeThenClose { input, output in
                                for try await buffer in input { try await output.write(buffer) }
                            }
                        }
                    }
                }
            }
        }
        let port = try #require(server.channel.localAddress?.port)
        return EchoServer(port: port, channel: server.channel, task: task)
    }

    /// Connects through the proxy with a domain-name CONNECT, sends `payload`, and returns the reply code and whatever
    /// came back through the tunnel.
    private static func connect(proxyPort: Int, host: String, port: Int, payload: String = "") async throws -> (reply: UInt8, echoed: String) {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: proxyPort) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var reader = inbound.makeAsyncIterator()
            var received: [UInt8] = []
            func need(_ count: Int) async throws {
                while received.count < count, let buffer = try await reader.next() { received.append(contentsOf: buffer.readableBytesView) }
            }
            try await outbound.write(ByteBuffer(bytes: [5, 1, 0]))
            try await need(2)
            #expect(Array(received.prefix(2)) == [5, 0])
            received.removeFirst(2)
            let name = Array(host.utf8)
            try await outbound.write(ByteBuffer(bytes: [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xff)]))
            try await need(10)
            let reply = received[1]
            received.removeFirst(10)
            guard reply == 0, !payload.isEmpty else { return (reply, "") }
            try await outbound.write(ByteBuffer(string: payload))
            try await need(payload.utf8.count)
            return (reply, String(decoding: received, as: UTF8.self))
        }
    }

    @Test("SOCKS5 requests parse for each address type and wait for more bytes when cut short")
    func parsing() {
        #expect(SOCKS5.greeting([5, 2, 0, 2]) == .parsed([0, 2], consumed: 4))
        #expect(SOCKS5.greeting([5, 2, 0]) == .needMore)
        #expect(SOCKS5.greeting([4, 1]) == .invalid(nil))
        #expect(SOCKS5.request([5, 1, 0, 3, 3] + Array("a.b".utf8) + [0, 80]) == .parsed(SOCKS5.Request(host: "a.b", port: 80), consumed: 10))
        #expect(SOCKS5.request([5, 1, 0, 1, 10, 0, 0, 1, 1, 187]) == .parsed(SOCKS5.Request(host: "10.0.0.1", port: 443), consumed: 10))
        #expect(SOCKS5.request([5, 1, 0, 4] + [UInt8](repeating: 0, count: 15) + [1, 0, 22]) == .parsed(SOCKS5.Request(host: "::1", port: 22), consumed: 22))
        #expect(SOCKS5.request([5, 1, 0, 3, 9, 97]) == .needMore)
        #expect(SOCKS5.request([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]) == .invalid(.commandNotSupported))
        #expect(SOCKS5.request([5, 1, 0, 9, 0]) == .invalid(.addressTypeNotSupported))
    }

    @Test("An allowed name tunnels to the address it resolved to")
    func tunnels() async throws {
        let echo = try await Self.echoServer()
        let proxy = BrowserNetworkProxy(
            policy: BrowserNetworkPolicy(allowsPrivateNetwork: true),
            resolver: ScriptedResolver(["echo.test": ["127.0.0.1"]])
        )
        let port = try await proxy.start()
        let result = try await Self.connect(proxyPort: port, host: "echo.test", port: echo.port, payload: "hello through the tunnel")
        #expect(result.reply == 0)
        #expect(result.echoed == "hello through the tunnel")
        #expect(await proxy.denials.isEmpty)
        await proxy.stop()
        await echo.stop()
    }

    @Test("Loopback is refused while private network access is off, and the refusal is recorded")
    func refusesLoopback() async throws {
        let echo = try await Self.echoServer()
        let proxy = BrowserNetworkProxy(policy: BrowserNetworkPolicy(), resolver: ScriptedResolver([:]))
        let port = try await proxy.start()
        let result = try await Self.connect(proxyPort: port, host: "127.0.0.1", port: echo.port, payload: "x")
        #expect(result.reply == SOCKS5.Reply.notAllowed.rawValue)
        let denials = await proxy.denials
        #expect(denials.map(\.host) == ["127.0.0.1"])
        #expect(denials.first?.reason.contains("loopback") == true)
        await proxy.stop()
        await echo.stop()
    }

    @Test("A public name that also resolves to a private address is refused")
    func refusesRebinding() async throws {
        let proxy = BrowserNetworkProxy(policy: BrowserNetworkPolicy(), resolver: ScriptedResolver(["rebind.test": ["93.184.216.34", "10.0.0.7"]]))
        let port = try await proxy.start()
        let result = try await Self.connect(proxyPort: port, host: "rebind.test", port: 443)
        #expect(result.reply == SOCKS5.Reply.notAllowed.rawValue)
        #expect(await proxy.denials.first?.reason == "rebind.test resolves to 10.0.0.7, a private address; private network access is off")
        await proxy.stop()
    }

    @Test("A blocked name is refused without being resolved")
    func blockedBeforeResolution() async throws {
        let resolver = ScriptedResolver(["ads.tracker.com": ["93.184.216.34"]])
        let proxy = BrowserNetworkProxy(policy: BrowserNetworkPolicy(blockedDomains: ["tracker.com"]), resolver: resolver)
        let port = try await proxy.start()
        let result = try await Self.connect(proxyPort: port, host: "ads.tracker.com", port: 443)
        #expect(result.reply == SOCKS5.Reply.notAllowed.rawValue)
        #expect(await resolver.asked.isEmpty)
        await proxy.stop()
    }

    @Test("A name that doesn't resolve fails closed")
    func unresolvable() async throws {
        let proxy = BrowserNetworkProxy(policy: BrowserNetworkPolicy(), resolver: ScriptedResolver([:]))
        let port = try await proxy.start()
        let result = try await Self.connect(proxyPort: port, host: "nowhere.example", port: 443)
        #expect(result.reply == SOCKS5.Reply.hostUnreachable.rawValue)
        #expect(await proxy.denials.first?.reason.hasPrefix("nowhere.example did not resolve") == true)
        await proxy.stop()
    }
}
