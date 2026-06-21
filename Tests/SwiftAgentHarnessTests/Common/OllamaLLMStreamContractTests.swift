import EasyJSON
import Foundation
import Logging
import OllamaKit
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Contract tests for ``OllamaLLM`` streaming behavior. Drive the adapter via
/// the ``OllamaChatStreamSourcing`` test seam so we can script the NDJSON chunk
/// sequence without standing up a real `URLSession`.
@Suite("OllamaLLM stream contract")
struct OllamaLLMStreamContractTests {

    // MARK: - Stub stream source

    private struct StubStreamSource: OllamaChatStreamSourcing {
        let chunks: [Result<OllamaChatStreamChunk, Error>]

        func chatStream(
            baseURL: URL,
            requestData: OKChatRequestData,
            timeout: TimeInterval?,
            logger: Logger?
        ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for entry in chunks {
                        switch entry {
                        case .success(let chunk):
                            continuation.yield(chunk)
                        case .failure(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                }
            }
        }
    }

    private final class CapturingStreamSource: @unchecked Sendable, OllamaChatStreamSourcing {
        private let lock = NSLock()
        private(set) var lastRequestData: OKChatRequestData?

        func chatStream(
            baseURL: URL,
            requestData: OKChatRequestData,
            timeout: TimeInterval?,
            logger: Logger?
        ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
            let _ = (baseURL, timeout, logger)
            lock.lock()
            lastRequestData = requestData
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        func observedRequestData() -> OKChatRequestData? {
            lock.lock()
            defer { lock.unlock() }
            return lastRequestData
        }
    }

    // MARK: - Helpers

    /// Decodes an `OllamaChatStreamChunk` from a JSON object string. Uses the
    /// adapter's own decoder so the snake-case + ISO8601 settings stay in sync.
    private func chunk(fromJSON json: String) throws -> OllamaChatStreamChunk {
        let data = Data(json.utf8)
        return try OllamaChatStreamSupport.jsonDecoderForChunks().decode(OllamaChatStreamChunk.self, from: data)
    }

    private func makeAdapter(streamSource: any OllamaChatStreamSourcing) async throws -> OllamaLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return OllamaLLM(
            model: "test-model",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion, .tools],
            systemPrompt: prompt,
            requestTimeoutInterval: nil,
            logger: nil,
            streamSource: streamSource
        )
    }

    private func consume(
        _ stream: AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>
    ) async -> (results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?) {
        var results: [StreamResult<LLMResponse, LLMResponse>] = []
        var terminal: Error?
        do {
            for try await element in stream {
                results.append(element)
            }
        } catch {
            terminal = error
        }
        return (results, terminal)
    }

    // MARK: - Tool call dedupe (Ollama replays the full tool list on the `done` chunk)

    @Test("tool calls in repeated done chunk are not duplicated on .complete")
    func toolCallsDedupedAcrossPerChunkAndDoneList() async throws {
        // Both the streaming chunk and the `done` chunk carry the same tool call. The
        // contract requires the .complete value to surface a single deduped entry.
        let streamingWithTool = try chunk(fromJSON: """
        {
            "model":"test-model",
            "createdAt":"2025-01-01T00:00:00Z",
            "message":{
                "role":"assistant",
                "content":"",
                "toolCalls":[{"function":{"name":"lookup","arguments":{"q":"x"}}}]
            },
            "done":false
        }
        """)
        let doneWithSameTool = try chunk(fromJSON: """
        {
            "model":"test-model",
            "createdAt":"2025-01-01T00:00:01Z",
            "message":{
                "role":"assistant",
                "content":"",
                "toolCalls":[{"function":{"name":"lookup","arguments":{"q":"x"}}}]
            },
            "done":true,
            "doneReason":"stop"
        }
        """)

        let source = StubStreamSource(chunks: [.success(streamingWithTool), .success(doneWithSameTool)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got results: \(results)")
            return
        }
        #expect(final.toolCalls.count == 1)
        #expect(final.toolCalls.first?.name == "lookup")
    }

    // MARK: - Cancellation

    @Test("cancelling the consuming Task surfaces CancellationError; no synthesized .complete; no _CANCELLED_ marker")
    func cancellationSurfacesCancellationError() async throws {
        // Source yields a streaming-content chunk then never finishes — a long-running
        // generation. We cancel the consuming task and confirm the contract terminal.
        let firstChunk = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"partial"},"done":false}
        """)

        struct NeverEndingSource: OllamaChatStreamSourcing {
            let firstChunk: OllamaChatStreamChunk
            func chatStream(
                baseURL: URL,
                requestData: OKChatRequestData,
                timeout: TimeInterval?,
                logger: Logger?
            ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
                let firstChunk = self.firstChunk
                return AsyncThrowingStream { continuation in
                    Task {
                        continuation.yield(firstChunk)
                        // Sleep until the parent task is cancelled.
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        continuation.finish()
                    }
                }
            }
        }

        let adapter = try await makeAdapter(streamSource: NeverEndingSource(firstChunk: firstChunk))
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let collector = Task<(results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?), Never> {
            await self.consume(stream)
        }
        // Give the producer a moment to yield its first chunk, then cancel.
        try? await Task.sleep(nanoseconds: 50_000_000)
        collector.cancel()
        let (results, terminal) = await collector.value

        // No .complete on the cancellation path; no `_CANCELLED_` sentinel in any chunk.
        for result in results {
            if case .complete(let final) = result {
                Issue.record("contract violation: synthesized .complete on cancellation; got \(final)")
            }
            if case .stream(let chunk) = result {
                #expect(!chunk.content.contains("_CANCELLED_"))
            }
        }
        // Terminal must surface CancellationError (or no terminal if the consumer task
        // exited before observing a thrown error from the producer; either is contract-conforming).
        if let terminal {
            #expect(terminal is CancellationError)
        }
    }

    // MARK: - Unknown stream errors wrap as LLMError.networkError(_:)

    @Test("unknown stream error wraps as LLMError.networkError(_:)")
    func unknownStreamErrorWrapsAsNetworkError() async throws {
        struct BoundaryError: Error {}
        let source = StubStreamSource(chunks: [.failure(BoundaryError())])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let (_, terminal) = await consume(stream)
        guard let llmError = terminal as? LLMError else {
            Issue.record("expected LLMError terminal, got \(String(describing: terminal))")
            return
        }
        switch llmError {
        case .networkError: break
        default: Issue.record("expected .networkError wrap, got \(llmError)")
        }
    }

    @Test("LLMError raised by stream source surfaces unchanged (no double-wrap)")
    func llmErrorSurfacesUnchanged() async throws {
        let source = StubStreamSource(chunks: [.failure(LLMError.timeout)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let (_, terminal) = await consume(stream)
        guard let llmError = terminal as? LLMError else {
            Issue.record("expected LLMError terminal, got \(String(describing: terminal))")
            return
        }
        switch llmError {
        case .timeout: break
        default: Issue.record("expected .timeout to pass through, got \(llmError)")
        }
    }

    // MARK: - Successful completion emits exactly one .complete

    @Test("successful stream emits exactly one .complete then finishes")
    func successPathEmitsExactlyOneComplete() async throws {
        let chunkA = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"hello "},"done":false}
        """)
        let chunkB = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:01Z","message":{"role":"assistant","content":"world"},"done":false}
        """)
        let done = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:02Z","message":{"role":"assistant","content":""},"done":true,"doneReason":"stop"}
        """)
        let source = StubStreamSource(chunks: [.success(chunkA), .success(chunkB), .success(done)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let completes = results.filter { if case .complete = $0 { return true } else { return false } }
        #expect(completes.count == 1)
        if case .complete(let final) = completes[0] {
            #expect(final.content == "hello world")
        }
    }

    @Test("terminal done chunk with content still emits a stream delta")
    func doneChunkOnlyContentEmitsDeltaAndComplete() async throws {
        let doneWithContent = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:02Z","message":{"role":"assistant","content":"terminal content"},"done":true,"doneReason":"stop"}
        """)
        let source = StubStreamSource(chunks: [.success(doneWithContent)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let streams = results.compactMap { result -> LLMResponse? in
            if case .stream(let chunk) = result { return chunk }
            return nil
        }
        #expect(streams.count == 1)
        #expect(streams.first?.content == "terminal content")
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got results: \(results)")
            return
        }
        #expect(final.content == "terminal content")
    }

    @Test("thinking-only chunk emits a .reasoning streaming fragment")
    func thinkingOnlyChunkEmitsReasoningFragment() async throws {
        let thinkingChunk = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"","thinking":"deliberating"},"done":false}
        """)
        let done = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:01Z","message":{"role":"assistant","content":""},"done":true,"doneReason":"stop"}
        """)
        let source = StubStreamSource(chunks: [.success(thinkingChunk), .success(done)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let reasoning = results.compactMap { result -> String? in
            guard case .stream(let chunk) = result,
                  case .reasoning(let text)? = chunk.streamingFragment else { return nil }
            return text
        }
        #expect(reasoning == ["deliberating"])
    }

    @Test("done chunk carrying thinking still surfaces reasoning then one .complete")
    func doneChunkThinkingSurfacesReasoning() async throws {
        let done = try chunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"","thinking":"final thought"},"done":true,"doneReason":"stop"}
        """)
        let source = StubStreamSource(chunks: [.success(done)])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let reasoning = results.compactMap { result -> String? in
            guard case .stream(let chunk) = result,
                  case .reasoning(let text)? = chunk.streamingFragment else { return nil }
            return text
        }
        #expect(reasoning == ["final thought"])
        let completes = results.filter { if case .complete = $0 { return true } else { return false } }
        #expect(completes.count == 1)
    }

    @Test("request mapping uses reasoning effort fallback and response format")
    func requestMappingUsesReasoningAndFormat() async throws {
        let source = CapturingStreamSource()
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let adapter = OllamaLLM(
            model: "test-model",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion, .tools, .thinking],
            systemPrompt: prompt,
            requestTimeoutInterval: nil,
            logger: nil,
            streamSource: source
        )
        let config = LLMRequestConfig(
            maxTokens: 1024,
            additionalParameters: .object([
                "thinkingConfig": .object(["level": .string("high")]),
                "responseFormat": .string("json_object"),
            ])
        )
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: config)
        _ = await consume(stream)
        let requestData = try #require(source.observedRequestData())
        #expect(requestData.think == true)
        if case .string(let value)? = requestData.format {
            #expect(value == "json")
        } else {
            Issue.record("expected JSON format override in request")
        }
    }
}
