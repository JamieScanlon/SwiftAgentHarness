import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Live view server")
struct DisplayLiveViewServerTests {
    /// What a feed was told.
    actor FeedLog {
        private(set) var counts: [Int] = []
        private(set) var inputs: [DisplayLiveViewInput] = []

        func viewers(_ count: Int) { counts.append(count) }
        func input(_ input: DisplayLiveViewInput) { inputs.append(input) }

        nonisolated var feed: DisplayLiveViewFeed {
            DisplayLiveViewFeed(label: "Managed browser", viewersChanged: { await self.viewers($0) }, input: { await self.input($0) })
        }
    }

    /// A viewer as a browser would connect: to `/stream`, presenting the fragment's token first.
    struct Viewer {
        let task: URLSessionWebSocketTask

        init(_ link: DisplayLiveView, origin: String? = nil, token: String? = nil, authenticates: Bool = true) throws {
            let url = try #require(URL(string: link.url))
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let fragment = components.fragment
            components.fragment = nil
            components.path = "/stream"
            components.scheme = "ws"
            var request = URLRequest(url: try #require(components.url))
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            task = URLSession.shared.webSocketTask(with: request)
            task.resume()
            if authenticates, let value = token ?? fragment {
                task.send(.string(#"{"type":"auth","token":"\#(value)"}"#)) { _ in }
            }
        }

        func send(_ text: String) async throws {
            try await task.send(.string(text))
        }

        /// The next message, or `nil` when the stream closed or nothing came within the timeout.
        func next(within timeout: Duration = .seconds(3)) async -> URLSessionWebSocketTask.Message? {
            await withTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try? await task.receive() }
                group.addTask {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return nil }
                    // receive() ignores task cancellation; cancelling the socket ends it.
                    task.cancel(with: .goingAway, reason: nil)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }

        /// Returns once the server has read everything sent before it.
        func roundTrip() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }

        /// The next status message, skipping frames.
        func status() async throws -> DisplayLiveViewServer.StatusMessage {
            while let message = await next() {
                if case .string(let text) = message {
                    return try JSONDecoder().decode(DisplayLiveViewServer.StatusMessage.self, from: Data(text.utf8))
                }
            }
            throw CancellationError()
        }

        /// The next frame, skipping status messages.
        func frame() async throws -> (width: Int, height: Int, control: Bool, jpeg: Data) {
            var received: Data?
            while received == nil, let message = await next() {
                if case .data(let data) = message { received = data }
            }
            guard let data = received else { throw CancellationError() }
            let bytes = [UInt8](data)
            let width = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
            let height = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
            return (width, height, bytes[8] == 1, data.dropFirst(9))
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])

    static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("A link carries its token only in the fragment and expires after the link lifetime")
    func link() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let server = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(linkLifetime: .seconds(120)), now: { start })
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let link = try await server.link(for: feed)
        let url = try #require(URLComponents(string: link.url))
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.path == "/view")
        #expect(url.query == nil)
        #expect((url.fragment?.count ?? 0) >= 43)
        #expect(link.viewOnly)
        #expect(link.expiresAt == start.addingTimeInterval(120))
        #expect(try await server.link(for: feed).url != link.url, "each link has its own token")
        await #expect(throws: DisplayTargetError.leaseNotHeld) { try await server.link(for: UUID()) }
    }

    @Test("The viewer page is served with headers that keep it out of frames, caches, and referrers")
    func page() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let base = try await server.start()
        let (body, response) = try await URLSession.shared.data(from: base.appendingPathComponent("view"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(http.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
        #expect(http.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
        let policy = try #require(http.value(forHTTPHeaderField: "Content-Security-Policy"))
        #expect(policy.contains("frame-ancestors 'none'"))
        #expect(policy.contains("script-src 'self'"))
        #expect(String(decoding: body, as: UTF8.self).contains("viewer.js"))

        let (_, script) = try await URLSession.shared.data(from: base.appendingPathComponent("viewer.js"))
        #expect((script as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)
        let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("other"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("A viewer with a valid token gets the status, the last frame, and new frames; the feed hears it come and go")
    func stream() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let log = FeedLog()
        let feed = await server.open(log.feed)
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 1280, height: 800), to: feed)

        let viewer = try Viewer(try await server.link(for: feed))
        #expect(try await viewer.status() == DisplayLiveViewServer.StatusMessage(type: "status", label: "Managed browser", control: false))
        let cached = try await viewer.frame()
        #expect(cached.width == 1280 && cached.height == 800 && !cached.control && cached.jpeg == Self.jpeg)
        #expect(await log.counts == [1])

        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 640, height: 400), to: feed)
        #expect(try await viewer.frame().width == 640)
        #expect(await server.viewerCount(feed) == 1)

        viewer.close()
        #expect(await Self.eventually { await log.counts == [1, 0] })
    }

    @Test("A wrong, expired, or missing token gets no frames")
    func refusedTokens() async throws {
        let clock = Clock()
        let server = DisplayLiveViewServer(
            configuration: DisplayLiveViewConfiguration(linkLifetime: .seconds(60), authenticationTimeout: .milliseconds(200)),
            now: { clock.now }
        )
        defer { Task { await server.stop() } }
        let log = FeedLog()
        let feed = await server.open(log.feed)
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 10, height: 10), to: feed)
        let link = try await server.link(for: feed)

        let wrong = try Viewer(link, token: "not-the-token")
        #expect(await wrong.next() == nil)
        let empty = try Viewer(link, token: "")
        #expect(await empty.next() == nil)
        let silent = try Viewer(link, authenticates: false)
        #expect(await silent.next() == nil, "a stream that never authenticates is closed")
        clock.advance(61)
        let expired = try Viewer(link)
        #expect(await expired.next() == nil)
        #expect(await log.counts.isEmpty)
    }

    @Test("A stream opened from another site's page is refused even with the token")
    func foreignOrigin() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let link = try await server.link(for: feed)
        let foreign = try Viewer(link, origin: "https://evil.example")
        #expect(await foreign.next(within: .seconds(1)) == nil)
        let base = try await server.start()
        let same = try Viewer(link, origin: String(base.absoluteString.dropLast()))
        #expect(try await same.status().type == "status")
    }

    @Test("Input reaches the feed only while it has control, and viewers hear control change")
    func control() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let log = FeedLog()
        let feed = await server.open(log.feed)
        let viewer = try Viewer(try await server.link(for: feed))
        #expect(try await viewer.status().control == false)

        try await viewer.send(#"{"type":"mouse","action":"down","x":10,"y":20,"button":"left","clickCount":1,"modifiers":[]}"#)
        try await viewer.roundTrip()
        await server.setControl(true, for: feed)
        #expect(try await viewer.status().control == true)
        #expect(try await server.link(for: feed).viewOnly == false)
        try await viewer.send(#"{"type":"mouse","action":"down","x":30,"y":40,"button":"left","clickCount":2,"modifiers":["shift","meta"]}"#)
        try await viewer.send(#"{"type":"text","text":"hunter2"}"#)
        try await viewer.send(#"{"type":"mouse","action":"down","x":"nope"}"#)
        #expect(await Self.eventually { await log.inputs.count == 2 })
        #expect(await log.inputs == [
            .mouse(.down, x: 30, y: 40, button: .left, clickCount: 2, modifiers: [.shift, .cmd]),
            .text("hunter2"),
        ])
    }

    @Test("Closing a feed ends its viewers and revokes its links")
    func close() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let link = try await server.link(for: feed)
        let viewer = try Viewer(link)
        _ = try await viewer.status()
        await server.close(feed)
        #expect(try await viewer.status().type == "ended")
        let late = try Viewer(link)
        #expect(await late.next() == nil)
    }

    @Test("A feed takes at most the configured number of viewers")
    func maxViewers() async throws {
        let server = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(maxViewersPerFeed: 1))
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let link = try await server.link(for: feed)
        let first = try Viewer(link)
        _ = try await first.status()
        let second = try Viewer(link)
        #expect(await second.next() == nil)
    }

    @Test("Viewer messages parse into input, and malformed ones are dropped")
    func parsing() {
        func parse(_ text: String) -> DisplayLiveViewInput? { DisplayLiveViewInput(message: Data(text.utf8)) }
        #expect(parse(#"{"type":"mouse","action":"move","x":1.5,"y":2}"#) == .mouse(.move, x: 1.5, y: 2, button: nil, clickCount: 1, modifiers: []))
        #expect(parse(#"{"type":"mouse","action":"down","x":1,"y":2}"#) == nil, "a press names its button")
        #expect(parse(#"{"type":"wheel","x":1,"y":2,"dx":0,"dy":-120,"modifiers":["ctrl"]}"#) == .wheel(x: 1, y: 2, dx: 0, dy: -120, modifiers: [.ctrl]))
        #expect(parse(#"{"type":"key","action":"down","key":"a","code":"KeyA","keyCode":65,"text":"a","modifiers":["alt"]}"#)
            == .key(down: true, key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: [.option]))
        #expect(parse(#"{"type":"key","action":"press","key":"a"}"#) == nil)
        #expect(parse(#"{"type":"text","text":""}"#) == nil)
        #expect(parse(#"{"type":"text","text":"\#(String(repeating: "x", count: 10_001))"}"#) == nil)
        #expect(parse(#"{"type":"clipboard"}"#) == nil)
    }

    final class Clock: Sendable {
        private let offset = Mutex<TimeInterval>(0)
        var now: Date { Date(timeIntervalSince1970: 1_800_000_000 + offset.withLock { $0 }) }
        func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
    }
}
