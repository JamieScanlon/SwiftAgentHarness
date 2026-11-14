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
        /// Read continuously, since URLSession handles a pong only while a receive is pending.
        private let inbox: AsyncStream<URLSessionWebSocketTask.Message>

        init(_ link: DisplayLiveView, origin: String? = nil, token: String? = nil, authenticates: Bool = true) throws {
            let url = try #require(URL(string: link.url))
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let fragment = components.fragment
            components.fragment = nil
            components.path = "/stream"
            components.scheme = "ws"
            var request = URLRequest(url: try #require(components.url))
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            let (inbox, received) = AsyncStream.makeStream(of: URLSessionWebSocketTask.Message.self)
            self.inbox = inbox
            task.resume()
            Task {
                while let message = try? await task.receive() { received.yield(message) }
                received.finish()
            }
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
                group.addTask {
                    var messages = inbox.makeAsyncIterator()
                    return await messages.next()
                }
                group.addTask {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return nil }
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
        let unused = try await server.link(for: feed)
        await server.close(feed)
        let ended = try await viewer.status()
        #expect(ended.type == "ended")
        #expect(ended.reason?.rawValue == "sessionEnded")
        let late = try Viewer(unused)
        #expect(await late.next() == nil)
    }

    @Test("A feed takes at most the configured number of viewers")
    func maxViewers() async throws {
        let server = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(maxViewersPerFeed: 1))
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let first = try Viewer(try await server.link(for: feed))
        _ = try await first.status()
        let second = try Viewer(try await server.link(for: feed))
        #expect(await second.next() == nil)
    }

    @Test("An observer link never carries input, even during takeover")
    func observerInput() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let log = FeedLog()
        let feed = await server.open(log.feed)
        await server.setControl(true, for: feed)
        let link = try await server.link(for: feed, role: .observer)
        #expect(link.role == .observer)
        #expect(link.viewOnly, "an observer link is view-only during takeover too")
        #expect(try await server.link(for: feed).role == .user)

        let observer = try Viewer(link)
        #expect(try await observer.status() == DisplayLiveViewServer.StatusMessage(type: "status", label: "Managed browser", control: false, observer: true, paused: true))
        try await observer.send(#"{"type":"text","text":"from the observer"}"#)
        try await observer.roundTrip()
        let user = try Viewer(try await server.link(for: feed))
        #expect(try await user.status().control == true)
        try await user.send(#"{"type":"text","text":"from the user"}"#)
        #expect(await Self.eventually { await log.inputs.count == 1 })
        try await observer.send(#"{"type":"text","text":"from the observer"}"#)
        try await observer.roundTrip()
        #expect(await log.inputs == [.text("from the user")])
    }

    @Test("Observers see no frames while the user has control, and catch up when it ends")
    func observerPause() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 100, height: 100), to: feed)
        let observer = try Viewer(try await server.link(for: feed, role: .observer))
        #expect(try await observer.status() == DisplayLiveViewServer.StatusMessage(type: "status", label: "Managed browser", control: false, observer: true, paused: false))
        #expect(try await observer.frame().width == 100)
        let user = try Viewer(try await server.link(for: feed))
        _ = try await user.frame()

        await server.setControl(true, for: feed)
        #expect(try await observer.status().paused == true)
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 200, height: 200), to: feed)
        #expect(try await user.frame().width == 200)
        let late = try Viewer(try await server.link(for: feed, role: .observer))
        #expect(try await late.status().paused == true)
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 300, height: 300), to: feed)
        #expect(try await user.frame().width == 300)

        await server.setControl(false, for: feed)
        #expect(try await observer.status().paused == false)
        #expect(try await observer.frame().width == 300, "the frames sent during takeover never reached it")
        #expect(try await late.status().paused == false)
        #expect(try await late.frame().width == 300)
    }

    @Test("Observers have their own viewer limit, so they can't crowd out the user")
    func observerLimit() async throws {
        let server = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(maxViewersPerFeed: 1, maxObserversPerFeed: 1))
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let first = try Viewer(try await server.link(for: feed, role: .observer))
        _ = try await first.status()
        let second = try Viewer(try await server.link(for: feed, role: .observer))
        #expect(await second.next() == nil)
        let user = try Viewer(try await server.link(for: feed))
        #expect(try await user.status().observer == nil)
        #expect(await server.viewerCount(feed) == 2)

        let closed = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(maxObserversPerFeed: 0))
        defer { Task { await closed.stop() } }
        let closedFeed = await closed.open(FeedLog().feed)
        await #expect(throws: DisplayTargetError.self) { try await closed.link(for: closedFeed, role: .observer) }
    }

    @Test("A shared target's feed takes no observers unless the host allows them; the user's links still work")
    func sharedFeedObservers() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let shared = await server.open(DisplayLiveViewFeed(label: "This Mac", isShared: true))
        await #expect(throws: DisplayTargetError.unsupported("observer links are off for This Mac, which is someone's own screen")) {
            try await server.link(for: shared, role: .observer)
        }
        let user = try Viewer(try await server.link(for: shared))
        _ = try await user.status()
        let unshared = await server.open(FeedLog().feed)
        _ = try await server.link(for: unshared, role: .observer)

        let allowing = DisplayLiveViewServer(configuration: DisplayLiveViewConfiguration(maxObserversPerSharedFeed: 1))
        defer { Task { await allowing.stop() } }
        let allowed = await allowing.open(DisplayLiveViewFeed(label: "This Mac", isShared: true))
        let observer = try Viewer(try await allowing.link(for: allowed, role: .observer))
        #expect(try await observer.status().observer == true)
        let second = try Viewer(try await allowing.link(for: allowed, role: .observer))
        #expect(await second.next() == nil, "the shared limit applies")
    }

    @Test("Ending observers closes their streams and revokes their links, and leaves the user's")
    func endObservers() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let observerLink = try await server.link(for: feed, role: .observer)
        let unusedObserverLink = try await server.link(for: feed, role: .observer)
        let userLink = try await server.link(for: feed)
        let unusedUserLink = try await server.link(for: feed)
        let observer = try Viewer(observerLink)
        _ = try await observer.status()
        let user = try Viewer(userLink)
        _ = try await user.status()
        #expect(await Self.eventually { await server.viewerCount(feed, role: .user) == 1 })
        #expect(await server.viewerCount(feed, role: .observer) == 1)

        await server.endObservers(feed)
        let ended = try await observer.status()
        #expect(ended.type == "ended")
        #expect(ended.reason?.rawValue == "sharingStopped")
        #expect(await (try Viewer(unusedObserverLink)).next(within: .seconds(1)) == nil)
        #expect(await Self.eventually { await server.viewerCount(feed) == 1 })
        #expect(try await (try Viewer(unusedUserLink)).status().type == "status")
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 50, height: 50), to: feed)
        #expect(try await user.frame().width == 50)
        #expect(try await server.link(for: feed, role: .observer).role == .observer, "new observer links can still be made")
    }

    @Test("A link connects once; the connection stays after its token is spent")
    func singleUse() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let feed = await server.open(FeedLog().feed)
        let link = try await server.link(for: feed)
        let viewer = try Viewer(link)
        _ = try await viewer.status()
        let replay = try Viewer(link)
        #expect(await replay.next(within: .seconds(1)) == nil, "the token was spent connecting")
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 20, height: 20), to: feed)
        #expect(try await viewer.frame().width == 20)
    }

    @Test("Connections are listed under their links' ids, and one can be revoked without the others")
    func revokeOne() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let log = FeedLog()
        let feed = await server.open(log.feed)
        let first = try await server.link(for: feed, role: .observer)
        let second = try await server.link(for: feed, role: .observer)
        let unused = try await server.link(for: feed, role: .observer)
        let a = try Viewer(first)
        _ = try await a.status()
        let b = try Viewer(second)
        _ = try await b.status()
        #expect(await Self.eventually { await server.connections(feed).count == 2 })
        #expect(Set(await server.connections(feed).map(\.id)) == [first.id, second.id])
        #expect(await server.connections(feed).allSatisfy { $0.role == .observer })

        #expect(await server.revoke(first.id, in: feed))
        let ended = try await a.status()
        #expect(ended.type == "ended")
        #expect(ended.reason?.rawValue == "revoked")
        #expect(await server.connections(feed).map(\.id) == [second.id])
        #expect(await Self.eventually { await log.counts.last == 1 })
        await server.publish(DisplayLiveViewFrame(jpeg: Self.jpeg, width: 30, height: 30), to: feed)
        #expect(try await b.frame().width == 30)

        #expect(await server.revoke(unused.id, in: feed), "an unused link is revoked before it connects")
        #expect(await (try Viewer(unused)).next(within: .seconds(1)) == nil)
        #expect(await server.revoke(UUID(), in: feed) == false)
    }

    @Test("Typing during takeover is gathered into values at Return, Tab, and the end of the takeover")
    func typingBuffer() {
        var buffer = DisplayLiveViewTypingBuffer()
        func key(_ key: String, _ text: String? = nil, _ modifiers: Set<KeyModifier> = []) -> DisplayLiveViewInput {
            .key(down: true, key: key, code: "", keyCode: 0, text: text, modifiers: modifiers)
        }
        #expect(buffer.record(key("h", "h")) == nil)
        #expect(buffer.record(key("i", "i")) == nil)
        #expect(buffer.record(key("x", "x")) == nil)
        #expect(buffer.record(key("Backspace")) == nil)
        #expect(buffer.record(key("c", "c", [.cmd])) == nil, "shortcuts aren't text")
        #expect(buffer.record(.text("!2")) == nil)
        #expect(buffer.record(key("Enter")) == "hi!2")
        #expect(buffer.record(key("Tab")) == nil, "nothing typed since")
        #expect(buffer.record(key("a", "a")) == nil)
        #expect(buffer.flush() == "a")
        #expect(buffer.flush() == nil)
    }

    @Test("The feed hears each value the user typed during takeover, including one left when control ends")
    func typedValues() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let typed = Mutex<[String]>([])
        let feed = await server.open(DisplayLiveViewFeed(label: "Feed", typed: { value in typed.withLock { $0.append(value) } }))
        await server.setControl(true, for: feed)
        let viewer = try Viewer(try await server.link(for: feed))
        _ = try await viewer.status()
        try await viewer.send(#"{"type":"text","text":"hunter2"}"#)
        try await viewer.send(#"{"type":"key","action":"down","key":"Enter","code":"Enter","keyCode":13,"modifiers":[]}"#)
        try await viewer.send(#"{"type":"text","text":"123456"}"#)
        try await viewer.roundTrip()
        #expect(await Self.eventually { typed.withLock { $0 } == ["hunter2"] })
        await server.setControl(false, for: feed)
        #expect(await Self.eventually { typed.withLock { $0 } == ["hunter2", "123456"] })
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
