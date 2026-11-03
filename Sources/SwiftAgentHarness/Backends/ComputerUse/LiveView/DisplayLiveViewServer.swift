import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization

public struct DisplayLiveViewConfiguration: Sendable {
    /// The address the server listens on. Loopback by default; a viewer on another machine reaches it through a
    /// tunnel or reverse proxy named by `publicBaseURL`.
    public var host: String
    /// `0` picks a free port.
    public var port: Int
    /// Where viewers reach the server, when that isn't `http://host:port/`. The proxy must pass `/view`,
    /// `/viewer.js`, and `/stream` through unchanged, including the WebSocket upgrade.
    public var publicBaseURL: URL?
    /// How long a link can be used to connect. A viewer that connected stays until the lease ends.
    public var linkLifetime: Duration
    /// How many of the user's viewers can watch one feed.
    public var maxViewersPerFeed: Int
    /// How many observers can watch one feed, counted apart from the user's viewers so they can't crowd them out.
    /// `0` turns observer links off.
    public var maxObserversPerFeed: Int
    /// How long a new stream has to present its link's token.
    public var authenticationTimeout: Duration

    public init(
        host: String = "127.0.0.1",
        port: Int = 0,
        publicBaseURL: URL? = nil,
        linkLifetime: Duration = .seconds(600),
        maxViewersPerFeed: Int = 4,
        maxObserversPerFeed: Int = 4,
        authenticationTimeout: Duration = .seconds(5)
    ) {
        self.host = host
        self.port = port
        self.publicBaseURL = publicBaseURL
        self.linkLifetime = linkLifetime
        self.maxViewersPerFeed = max(1, maxViewersPerFeed)
        self.maxObserversPerFeed = max(0, maxObserversPerFeed)
        self.authenticationTimeout = authenticationTimeout
    }
}

/// Serves live views of display targets: a viewer page and a WebSocket stream of frames. Links carry a short-lived
/// token in the URL fragment, so it never appears in a request line or a log. A viewer is view-only, and the user's
/// input reaches the target only while the feed has control, which a target gives it during takeover. An observer's
/// input never does, and observers see no frames while the feed has control.
///
/// One server can carry many feeds, one per leased target.
public actor DisplayLiveViewServer {
    public nonisolated let configuration: DisplayLiveViewConfiguration
    private let now: @Sendable () -> Date
    private var server: NIOAsyncChannel<EventLoopFuture<Connection>, Never>?
    private var acceptor: Task<Void, Never>?
    private var starting: Task<URL, any Error>?
    private var feeds: [UUID: Feed] = [:]
    private var links: [String: Link] = [:]

    enum Connection: Sendable {
        case stream(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>)
    }

    enum Outgoing: Sendable {
        case frame(DisplayLiveViewFrame, control: Bool)
        case status(StatusMessage)
        case ended(StatusMessage.EndReason)
    }

    private struct Viewer {
        var role: DisplayLiveViewRole
        var messages: AsyncStream<Outgoing>.Continuation
    }

    private struct Feed {
        var feed: DisplayLiveViewFeed
        var control = false
        var lastFrame: DisplayLiveViewFrame?
        var viewers: [UUID: Viewer] = [:]

        func count(_ role: DisplayLiveViewRole) -> Int {
            viewers.values.count { $0.role == role }
        }

        func status(for role: DisplayLiveViewRole) -> StatusMessage {
            switch role {
            case .user: StatusMessage(type: "status", label: feed.label, control: control)
            case .observer: StatusMessage(type: "status", label: feed.label, control: false, observer: true, paused: control)
            }
        }

        /// What the viewer is sent of `frame`: nothing for an observer while the user has control.
        func outgoing(_ frame: DisplayLiveViewFrame, for role: DisplayLiveViewRole) -> Outgoing? {
            switch role {
            case .user: .frame(frame, control: control)
            case .observer: control ? nil : .frame(frame, control: false)
            }
        }
    }

    private struct Link {
        var feedID: UUID
        var role: DisplayLiveViewRole
        var expiresAt: Date
    }

    public init(configuration: DisplayLiveViewConfiguration = DisplayLiveViewConfiguration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
    }

    /// Starts listening if it isn't already, and returns the base viewers reach it at.
    @discardableResult
    public func start() async throws -> URL {
        if let starting { return try await starting.value }
        let task = Task { try await bind() }
        starting = task
        do {
            return try await task.value
        } catch {
            starting = nil
            throw error
        }
    }

    private func bind() async throws -> URL {
        let maxFrame = 1 << 16
        let originBox = OriginBox()
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: configuration.host, port: configuration.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
                        maxFrameSize: maxFrame,
                        shouldUpgrade: { channel, head in
                            let allowed = head.uri == "/stream" && originBox.allows(head.headers.first(name: "origin"))
                            return channel.eventLoop.makeSucceededFuture(allowed ? HTTPHeaders() : nil)
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                .stream(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: NIOUpgradableHTTPServerPipelineConfiguration(
                            upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration(
                                upgraders: [upgrader],
                                notUpgradingCompletionHandler: { channel in
                                    channel.eventLoop.makeCompletedFuture {
                                        .http(try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel))
                                    }
                                }
                            )
                        )
                    )
                }
            }
        guard let port = server.channel.localAddress?.port else {
            try? await server.channel.close()
            throw DisplayTargetError.driverFailure("the live view server has no port")
        }
        let base = Self.base(configuration.publicBaseURL ?? URL(string: "http://\(Self.authority(configuration.host, port))/")!)
        originBox.set(Self.origin(of: base))
        self.server = server
        let page = Self.headers(for: base)
        acceptor = Task {
            try? await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in inbound {
                        group.addTask {
                            switch try? await connection.get() {
                            case .stream(let channel)?: await self.serve(channel)
                            case .http(let channel)?: await Self.serve(channel, headers: page)
                            case nil: break
                            }
                        }
                    }
                }
            }
        }
        return base
    }

    public func stop() async {
        for id in Array(feeds.keys) { close(id) }
        try? await server?.channel.close()
        acceptor?.cancel()
        await acceptor?.value
        server = nil
        acceptor = nil
        starting = nil
    }

    // MARK: - Feeds

    public func open(_ feed: DisplayLiveViewFeed) -> UUID {
        let id = UUID()
        feeds[id] = Feed(feed: feed)
        return id
    }

    /// Ends the feed's viewers and revokes its links.
    public func close(_ id: UUID) {
        guard let feed = feeds.removeValue(forKey: id) else { return }
        for viewer in feed.viewers.values {
            viewer.messages.yield(.ended(.sessionEnded))
            viewer.messages.finish()
        }
        links = links.filter { $0.value.feedID != id }
    }

    /// A new link to the feed. `viewOnly` is whether its input is ignored right now; for the user's links it changes
    /// with control, and an observer's is always view-only.
    public func link(for id: UUID, role: DisplayLiveViewRole = .user) async throws -> DisplayLiveView {
        guard feeds[id] != nil else { throw DisplayTargetError.leaseNotHeld }
        if role == .observer, configuration.maxObserversPerFeed == 0 {
            throw DisplayTargetError.unsupported("observer links are turned off")
        }
        let base = try await start()
        guard let feed = feeds[id] else { throw DisplayTargetError.leaseNotHeld }
        let token = Self.token()
        let expiresAt = now().addingTimeInterval(configuration.linkLifetime.timeInterval)
        links = links.filter { $0.value.expiresAt > now() }
        links[token] = Link(feedID: id, role: role, expiresAt: expiresAt)
        var components = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
        components.fragment = token
        return DisplayLiveView(
            url: components.url!.absoluteString,
            viewOnly: role == .observer || !feed.control,
            expiresAt: expiresAt,
            role: role
        )
    }

    /// Ends the feed's observers and revokes its observer links. The user's viewers and links are kept.
    public func endObservers(_ id: UUID) {
        guard let feed = feeds[id] else { return }
        for viewer in feed.viewers.values where viewer.role == .observer {
            viewer.messages.yield(.ended(.sharingStopped))
            viewer.messages.finish()
        }
        links = links.filter { $0.value.feedID != id || $0.value.role != .observer }
    }

    public func publish(_ frame: DisplayLiveViewFrame, to id: UUID) {
        guard var feed = feeds[id] else { return }
        feed.lastFrame = frame
        feeds[id] = feed
        for viewer in feed.viewers.values {
            if let message = feed.outgoing(frame, for: viewer.role) { viewer.messages.yield(message) }
        }
    }

    /// Whether the user's viewers' input reaches the target. Observers are paused while it does.
    public func setControl(_ on: Bool, for id: UUID) {
        guard var feed = feeds[id], feed.control != on else { return }
        feed.control = on
        feeds[id] = feed
        for viewer in feed.viewers.values {
            viewer.messages.yield(.status(feed.status(for: viewer.role)))
            if viewer.role == .observer, let frame = feed.lastFrame, let message = feed.outgoing(frame, for: .observer) {
                viewer.messages.yield(message)
            }
        }
    }

    /// The feed's viewers, or only those with `role`.
    public func viewerCount(_ id: UUID, role: DisplayLiveViewRole? = nil) -> Int {
        guard let feed = feeds[id] else { return 0 }
        guard let role else { return feed.viewers.count }
        return feed.count(role)
    }

    // MARK: - Viewers

    private func admit(_ token: String) async -> (feed: UUID, viewer: UUID, messages: AsyncStream<Outgoing>)? {
        guard let link = links[token], link.expiresAt > now(), var feed = feeds[link.feedID] else { return nil }
        let limit = link.role == .user ? configuration.maxViewersPerFeed : configuration.maxObserversPerFeed
        guard feed.count(link.role) < limit else { return nil }
        let viewer = UUID()
        let (messages, continuation) = AsyncStream<Outgoing>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuation.yield(.status(feed.status(for: link.role)))
        if let frame = feed.lastFrame, let message = feed.outgoing(frame, for: link.role) { continuation.yield(message) }
        feed.viewers[viewer] = Viewer(role: link.role, messages: continuation)
        feeds[link.feedID] = feed
        await feed.feed.viewersChanged(feed.viewers.count)
        return (link.feedID, viewer, messages)
    }

    private func leave(_ feedID: UUID, _ viewer: UUID) async {
        guard var feed = feeds[feedID], let removed = feed.viewers.removeValue(forKey: viewer) else { return }
        removed.messages.finish()
        feeds[feedID] = feed
        await feed.feed.viewersChanged(feed.viewers.count)
    }

    private func receive(_ input: DisplayLiveViewInput, from feedID: UUID, viewer: UUID) async {
        guard let feed = feeds[feedID], feed.control, feed.viewers[viewer]?.role == .user else { return }
        await feed.feed.input(input)
    }

    private nonisolated func serve(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async {
        let raw = channel.channel
        let timeout = configuration.authenticationTimeout
        let deadline = Task {
            try await Task.sleep(for: timeout)
            raw.close(promise: nil)
        }
        defer { deadline.cancel() }
        try? await channel.executeThenClose { inbound, outbound in
            var reader = inbound.makeAsyncIterator()
            guard let first = try await reader.next(), first.opcode == .text,
                  let token = Self.authToken(first.unmaskedData),
                  let admitted = await self.admit(token)
            else {
                try? await outbound.write(Self.closeFrame(code: 1008))
                return
            }
            deadline.cancel()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await message in admitted.messages {
                            switch message {
                            case .frame(let frame, let control):
                                try await outbound.write(Self.binaryFrame(frame, control: control))
                            case .status(let status):
                                try await outbound.write(Self.textFrame(status))
                            case .ended(let reason):
                                try await outbound.write(Self.textFrame(StatusMessage(type: "ended", reason: reason)))
                                try await outbound.write(Self.closeFrame(code: 1000))
                                raw.close(promise: nil)
                                return
                            }
                        }
                    }
                    while let frame = try await reader.next() {
                        switch frame.opcode {
                        case .text:
                            if let input = DisplayLiveViewInput(message: Data(frame.unmaskedData.readableBytesView)) {
                                await self.receive(input, from: admitted.feed, viewer: admitted.viewer)
                            }
                        case .ping:
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        case .connectionClose:
                            try? await outbound.write(Self.closeFrame(code: 1000))
                            group.cancelAll()
                            return
                        default:
                            break
                        }
                    }
                    group.cancelAll()
                }
            } catch {}
            await self.leave(admitted.feed, admitted.viewer)
        }
    }

    private static func serve(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, headers: HTTPHeaders) async {
        try? await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
                let (status, type, body): (HTTPResponseStatus, String, String) = switch (head.method, path) {
                case (.GET, "/view"): (.ok, "text/html; charset=utf-8", DisplayLiveViewViewer.html)
                case (.GET, "/viewer.js"): (.ok, "text/javascript; charset=utf-8", DisplayLiveViewViewer.script)
                case (.GET, "/stream"): (.forbidden, "text/plain; charset=utf-8", "Forbidden")
                case (.GET, _): (.notFound, "text/plain; charset=utf-8", "Not found")
                default: (.methodNotAllowed, "text/plain; charset=utf-8", "Method not allowed")
                }
                var response = headers
                response.add(name: "Content-Type", value: type)
                response.add(name: "Content-Length", value: String(body.utf8.count))
                try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: response)))
                try await outbound.write(.body(.byteBuffer(ByteBuffer(string: body))))
                try await outbound.write(.end(nil))
                return
            }
        }
    }

    // MARK: - Wire

    static func authToken(_ buffer: ByteBuffer) -> String? {
        struct Auth: Decodable {
            var type: String
            var token: String
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: Data(buffer.readableBytesView)), auth.type == "auth", !auth.token.isEmpty else { return nil }
        return auth.token
    }

    /// Width and height as big-endian 32-bit integers, a control flag byte, then the JPEG.
    static func binaryFrame(_ frame: DisplayLiveViewFrame, control: Bool) -> WebSocketFrame {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(clamping: frame.width))
        buffer.writeInteger(UInt32(clamping: frame.height))
        buffer.writeInteger(UInt8(control ? 1 : 0))
        buffer.writeBytes(frame.jpeg)
        return WebSocketFrame(fin: true, opcode: .binary, data: buffer)
    }

    struct StatusMessage: Codable, Equatable, Sendable {
        var type: String
        var label: String?
        var control: Bool?
        /// Set only for observers.
        var observer: Bool?
        /// Whether the user has control, so an observer is sent no frames.
        var paused: Bool?
        /// Why an `ended` stream ended.
        var reason: EndReason?

        enum EndReason: String, Codable, Sendable {
            case sessionEnded
            /// The user stopped sharing with observers; the session goes on.
            case sharingStopped
        }
    }

    private static func textFrame(_ message: StatusMessage) -> WebSocketFrame {
        let data = (try? JSONEncoder().encode(message)) ?? Data("{}".utf8)
        return WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: data))
    }

    private static func closeFrame(code: UInt16) -> WebSocketFrame {
        var buffer = ByteBuffer()
        buffer.writeInteger(code)
        return WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
    }

    static func headers(for base: URL) -> HTTPHeaders {
        let socket = (base.scheme == "https" ? "wss://" : "ws://") + authority(of: base)
        return HTTPHeaders([
            ("Cache-Control", "no-store"),
            ("Referrer-Policy", "no-referrer"),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self' \(socket); img-src blob:; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
            ("Connection", "close"),
        ])
    }

    static func token() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base(_ url: URL) -> URL {
        url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/")!
    }

    static func authority(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func authority(of url: URL) -> String {
        let host = url.host.map { $0.contains(":") ? "[\($0)]" : $0 } ?? ""
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    static func origin(of url: URL) -> String {
        "\(url.scheme ?? "http")://\(authority(of: url))".lowercased()
    }

    /// The server's own origin, set once it has a port. A stream opened from any other page is refused; one with no
    /// `Origin` header (a native client) still needs a token.
    private final class OriginBox: Sendable {
        private let value = Mutex<String?>(nil)

        func set(_ origin: String) {
            value.withLock { $0 = origin }
        }

        func allows(_ origin: String?) -> Bool {
            guard let origin else { return true }
            return value.withLock { $0 == origin.lowercased() }
        }
    }
}
