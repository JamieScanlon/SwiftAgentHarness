import Foundation
import Network
import NIOCore
import NIOPosix
import Synchronization
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

/// Gates release of assistant partials so tests can assert HTTP head flush before TTFT.
private actor PartialReleaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private enum EarlyFlushTestSupport {
    static func gatedChatStream(
        conversationID: UUID = UUID(),
        gate: PartialReleaseGate,
        chunks: [String]
    ) -> ChatStreamResponse {
        let partialContent = AsyncStream<ChatStreamingPartial> { continuation in
            Task {
                await gate.waitUntilOpen()
                for chunk in chunks {
                    continuation.yield(.text(chunk))
                }
                continuation.finish()
            }
        }
        let orchestrationState = AsyncStream<ConversationOrchestrationState> { continuation in
            continuation.finish()
        }
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: orchestrationState,
            conversationID: conversationID
        )
    }

    static func immediateChatStream(
        conversationID: UUID = UUID(),
        chunks: [String]
    ) -> ChatStreamResponse {
        let partialContent = AsyncStream<ChatStreamingPartial> { continuation in
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            continuation.finish()
        }
        let orchestrationState = AsyncStream<ConversationOrchestrationState> { continuation in
            continuation.finish()
        }
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: orchestrationState,
            conversationID: conversationID
        )
    }

    /// Leading whitespace (if any) from an early keepalive flush; remainder is assistant text.
    static func assistantText(fromHTTPBody body: String) -> String {
        String(body.drop(while: { $0.isWhitespace }))
    }

    static func isIgnorableFlush(_ text: String) -> Bool {
        text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct RecordingWriterState: Sendable {
    var results: [BodyStreamResult] = []
    var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    var didObserveFirstWrite = false
}

/// Records stream writes; fulfills promises immediately so EventLoop scheduling is not required for ordering asserts.
private final class RecordingBodyStreamWriter: BodyStreamWriter, @unchecked Sendable {
    let eventLoop: any EventLoop
    private let state = Mutex(RecordingWriterState())

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    func write(_ result: BodyStreamResult, promise: EventLoopPromise<Void>?) {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.results.append(result)
            guard !state.didObserveFirstWrite else { return [] }
            state.didObserveFirstWrite = true
            let pending = state.firstWriteWaiters
            state.firstWriteWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
        promise?.succeed(())
    }

    func waitForFirstWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately = state.withLock { state -> Bool in
                if state.didObserveFirstWrite {
                    return true
                }
                state.firstWriteWaiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func snapshot() -> [BodyStreamResult] {
        state.withLock { $0.results }
    }
}

private struct EarlyFlushHeaderTimeout: Error {}

/// Minimal TCP client that returns as soon as the HTTP response head (and any already-buffered
/// first body bytes) are readable — used to assert early flush without URLSession.
private enum EarlyFlushTCPClient {
    static func readHTTPHead(host: String, port: Int, path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "early-flush-tcp")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp
            )
            let state = TCPReadBox(continuation: continuation, connection: connection)

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    let request = Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error {
                            state.fail(error)
                        } else {
                            Self.receive(into: state)
                        }
                    })
                case .failed(let error):
                    state.fail(error)
                case .cancelled:
                    state.fail(CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func receive(into state: TCPReadBox) {
        guard let connection = state.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            if let error {
                state.fail(error)
                return
            }
            if let content {
                state.append(content)
            }
            if state.hasCompleteHTTPHead {
                state.succeed()
                return
            }
            if isComplete {
                state.fail(EarlyFlushHeaderTimeout())
                return
            }
            Self.receive(into: state)
        }
    }
}

private final class TCPReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var connection: NWConnection?
    private var buffer = Data()

    var hasCompleteHTTPHead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    init(continuation: CheckedContinuation<Data, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func succeed() {
        lock.lock()
        let cont = continuation
        let data = buffer
        continuation = nil
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
        cont?.resume(returning: data)
    }

    func fail(_ error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
        cont?.resume(throwing: error)
    }
}

@Suite("APILayer streaming early flush")
struct APILayerStreamingEarlyFlushTests {
    @Test("streamingChatResponse writes flush buffer before awaiting partialContent")
    func writerFlushesBeforeAwaitingPartials() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let gate = PartialReleaseGate()
            let stream = EarlyFlushTestSupport.gatedChatStream(gate: gate, chunks: ["hello"])
            let writer = RecordingBodyStreamWriter(eventLoop: group.next())
            let callback = APILayer.makeStreamingChatBodyStreamCallback(stream: stream)
            callback(writer)

            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    await writer.waitForFirstWrite()
                }
                taskGroup.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw EarlyFlushHeaderTimeout()
                }
                try await taskGroup.next()
                taskGroup.cancelAll()
            }

            let beforeRelease = writer.snapshot()
            #expect(beforeRelease.count >= 1)
            if case .buffer(let buffer) = beforeRelease[0] {
                let text = String(buffer: buffer)
                #expect(EarlyFlushTestSupport.isIgnorableFlush(text))
            } else {
                Issue.record("Expected first write to be a buffer flush, got \(beforeRelease[0])")
            }
            #expect(beforeRelease.contains { if case .end = $0 { return true }; return false } == false)

            await gate.open()

            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    while true {
                        let snap = writer.snapshot()
                        if snap.contains(where: { if case .end = $0 { return true }; return false }) {
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                taskGroup.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw EarlyFlushHeaderTimeout()
                }
                try await taskGroup.next()
                taskGroup.cancelAll()
            }

            let after = writer.snapshot()
            let buffers = after.compactMap { result -> String? in
                guard case .buffer(let buffer) = result else { return nil }
                return String(buffer: buffer)
            }
            let concatenated = buffers.joined()
            #expect(EarlyFlushTestSupport.assistantText(fromHTTPBody: concatenated) == "hello")
            #expect(after.contains { if case .end = $0 { return true }; return false })
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    @Test("live HTTP client observes 200 before first partial is released")
    func liveServerObserves200BeforeFirstPartial() async throws {
        let gate = PartialReleaseGate()
        let stream = EarlyFlushTestSupport.gatedChatStream(gate: gate, chunks: ["after-flush"])

        try await withApp { app in
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0
            app.get("early-flush") { _ async throws -> Response in
                try await APILayer.streamingChatResponse(stream: stream)
            }

            try await app.asyncBoot()
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            do {
                let port = try #require(app.http.server.shared.localAddress?.port)

                // Read the HTTP head with a raw TCP client so we observe wire flush timing
                // independently of URLSession.AsyncBytes buffering quirks.
                let headerBytes = try await withThrowingTaskGroup(of: Data.self) { taskGroup in
                    taskGroup.addTask {
                        try await EarlyFlushTCPClient.readHTTPHead(
                            host: "127.0.0.1",
                            port: port,
                            path: "/early-flush"
                        )
                    }
                    taskGroup.addTask {
                        try await Task.sleep(for: .seconds(2))
                        throw EarlyFlushHeaderTimeout()
                    }
                    let first = try await taskGroup.next()!
                    taskGroup.cancelAll()
                    return first
                }

                let headerText = String(data: headerBytes, encoding: .utf8) ?? ""
                #expect(headerText.contains("HTTP/1.1 200"))
                // Keepalive chunk should already be on the wire with the head.
                #expect(headerText.contains("\r\n1\r\n\n") || headerText.contains("Transfer-Encoding: chunked"))

                await gate.open()
                // Give the stream a moment to finish writing after the gate opens.
                try await Task.sleep(for: .milliseconds(100))
            } catch is EarlyFlushHeaderTimeout {
                Issue.record("HTTP 200 headers were not observed within 2s while partials were still gated")
                await app.server.shutdown()
                throw EarlyFlushHeaderTimeout()
            } catch {
                await app.server.shutdown()
                throw error
            }
            await app.server.shutdown()
        }
    }

    @Test("concatenated body is whitespace-prefix plus assistant text")
    func bodyIntegrityAfterFlushAndPartials() async throws {
        let stream = EarlyFlushTestSupport.immediateChatStream(chunks: ["chunk-1", "chunk-2"])

        try await withApp { app in
            app.post("early-flush-body") { _ async throws -> Response in
                try await APILayer.streamingChatResponse(stream: stream)
            }

            try await app.testing().test(.POST, "/early-flush-body", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.hasPrefix("\n"))
                #expect(EarlyFlushTestSupport.assistantText(fromHTTPBody: body) == "chunk-1chunk-2")
            })
        }
    }

    @Test("stream with no tokens still ends cleanly with HTTP 200")
    func zeroTokenStreamEndsCleanly() async throws {
        let stream = EarlyFlushTestSupport.immediateChatStream(chunks: [])

        try await withApp { app in
            app.post("early-flush-empty") { _ async throws -> Response in
                try await APILayer.streamingChatResponse(stream: stream)
            }

            try await app.testing().test(.POST, "/early-flush-empty", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(EarlyFlushTestSupport.isIgnorableFlush(body))
            })
        }
    }
}
