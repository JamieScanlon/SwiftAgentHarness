import EasyJSON
import Foundation

/// Carries Chrome DevTools Protocol messages, one JSON text per message.
public protocol CDPTransport: Sendable {
    /// Every message the browser sends, in order; finishes when the connection closes.
    var messages: AsyncThrowingStream<String, any Error> { get }
    func send(_ message: String) async throws
    func close() async
}

public struct CDPError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public var description: String { "\(message) (\(code))" }

    static let closed = CDPError(code: -1, message: "the browser connection closed")
    static func timedOut(_ method: String) -> CDPError { CDPError(code: -2, message: "\(method) timed out") }
}

public struct CDPEvent: Sendable {
    public var method: String
    public var params: JSON
    public var sessionID: String?
}

/// What a managed browser target needs from a CDP connection. Commands carry a session id once a page target is
/// attached in flat mode.
public protocol CDPSending: Sendable {
    func send(_ method: String, _ params: JSON, session: String?) async throws -> JSON
    /// Events from the moment of the call on.
    func events() async -> AsyncStream<CDPEvent>
}

public extension CDPSending {
    func send(_ method: String, _ params: [String: JSON] = [:], session: String? = nil) async throws -> JSON {
        try await send(method, .object(params), session: session)
    }
}

/// A CDP client over one transport: numbers commands, matches replies, and fans events out to subscribers.
public actor CDPConnection: CDPSending {
    private let transport: any CDPTransport
    private let timeout: Duration
    private var nextID = 1
    private var pending: [Int: (continuation: CheckedContinuation<JSON, any Error>, timer: Task<Void, Never>)] = [:]
    private var subscribers: [UUID: AsyncStream<CDPEvent>.Continuation] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false

    public init(transport: any CDPTransport, timeout: Duration = .seconds(30)) {
        self.transport = transport
        self.timeout = timeout
    }

    public func start() {
        guard reader == nil else { return }
        let messages = transport.messages
        reader = Task { [weak self] in
            do {
                for try await text in messages {
                    await self?.receive(text)
                }
            } catch {}
            await self?.finish()
        }
    }

    public func send(_ method: String, _ params: JSON, session: String?) async throws -> JSON {
        guard !closed else { throw CDPError.closed }
        let id = nextID
        nextID += 1
        var message: [String: JSON] = ["id": .integer(id), "method": .string(method), "params": params]
        if let session { message["sessionId"] = .string(session) }
        let text = String(decoding: try JSONEncoder().encode(JSON.object(message)), as: UTF8.self)
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.fail(id, CDPError.timedOut(method))
            }
            pending[id] = (continuation, timer)
            let transport = transport
            Task { [weak self] in
                do {
                    try await transport.send(text)
                } catch {
                    await self?.fail(id, error)
                }
            }
        }
    }

    public func events() -> AsyncStream<CDPEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CDPEvent.self, bufferingPolicy: .bufferingNewest(500))
        guard !closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    public func close() async {
        await transport.close()
        finish()
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func receive(_ text: String) {
        guard let message = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else { return }
        if let id = message[wire: "id"]?.wireInt {
            guard let entry = pending.removeValue(forKey: id) else { return }
            entry.timer.cancel()
            if let error = message[wire: "error"] {
                entry.continuation.resume(throwing: CDPError(
                    code: error[wire: "code"]?.wireInt ?? 0,
                    message: error[wire: "message"]?.wireString ?? "unknown error"
                ))
            } else {
                entry.continuation.resume(returning: message[wire: "result"] ?? .object([:]))
            }
        } else if let method = message[wire: "method"]?.wireString {
            let event = CDPEvent(method: method, params: message[wire: "params"] ?? .object([:]), sessionID: message[wire: "sessionId"]?.wireString)
            for subscriber in subscribers.values { subscriber.yield(event) }
        }
    }

    private func fail(_ id: Int, _ error: any Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        for (_, entry) in pending {
            entry.timer.cancel()
            entry.continuation.resume(throwing: CDPError.closed)
        }
        pending.removeAll()
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }
}

/// CDP over a pair of pipes (`--remote-debugging-pipe`): messages are NUL-terminated, and no port is opened that
/// another local process, or a page, could connect to.
public final class CDPPipeTransport: CDPTransport {
    public let messages: AsyncThrowingStream<String, any Error>
    private let writer: FileHandle
    private let reader: FileHandle
    // FileHandle writes are synchronous; the lock keeps concurrent sends from interleaving their bytes.
    private let writeLock = NSLock()

    /// Takes ownership of both descriptors.
    public init(readFrom readDescriptor: Int32, writeTo writeDescriptor: Int32) {
        let reader = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
        self.reader = reader
        writer = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
        messages = stream
        let thread = Thread {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 0) {
                    continuation.yield(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...end)
                }
            }
            continuation.finish()
        }
        thread.name = "cdp-pipe-reader"
        thread.start()
    }

    public func send(_ message: String) async throws {
        var data = Data(message.utf8)
        data.append(0)
        try writeLock.withLock { try writer.write(contentsOf: data) }
    }

    public func close() async {
        writeLock.withLock { try? writer.close() }
    }
}

/// CDP over a WebSocket, for a browser reached by its DevTools URL, such as a hosted browser.
public final class CDPWebSocketTransport: CDPTransport {
    public let messages: AsyncThrowingStream<String, any Error>
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        let task = session.webSocketTask(with: url)
        // Screenshots arrive as one base64 message, far above the 1 MB default.
        task.maximumMessageSize = 64 << 20
        self.task = task
        messages = AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(text)
                        case .data(let data): continuation.yield(String(decoding: data, as: UTF8.self))
                        @unknown default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        task.resume()
    }

    public func send(_ message: String) async throws {
        try await task.send(.string(message))
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
