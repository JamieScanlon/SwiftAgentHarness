import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AnthropicLLM stream contract")
struct AnthropicLLMStreamContractTests {

    private struct StubStreamSource: AnthropicStreamSourcing {
        let events: [Result<AnthropicStreamEvent, Error>]

        func messageStream(
            apiURL: URL,
            apiKey: String,
            requestBody: Data,
            logger: Logger?
        ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
            let _ = (apiURL, apiKey, requestBody, logger)
            return AsyncThrowingStream { continuation in
                Task {
                    for entry in events {
                        switch entry {
                        case .success(let event):
                            continuation.yield(event)
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

    private struct NeverEndingStreamSource: AnthropicStreamSourcing {
        let firstEvent: AnthropicStreamEvent

        func messageStream(
            apiURL: URL,
            apiKey: String,
            requestBody: Data,
            logger: Logger?
        ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
            let _ = (apiURL, apiKey, requestBody, logger)
            let firstEvent = self.firstEvent
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(firstEvent)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    continuation.finish()
                }
            }
        }
    }

    private final class CapturingStreamSource: @unchecked Sendable, AnthropicStreamSourcing {
        private let lock = NSLock()
        private(set) var lastAPIURL: URL?
        private(set) var lastRequestBody: Data?

        func messageStream(
            apiURL: URL,
            apiKey: String,
            requestBody: Data,
            logger: Logger?
        ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
            let _ = (apiKey, logger)
            lock.lock()
            lastAPIURL = apiURL
            lastRequestBody = requestBody
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        func observedAPIURL() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return lastAPIURL
        }

        func observedRequestBody() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lastRequestBody
        }
    }

    private func makeAdapter(streamSource: any AnthropicStreamSourcing) async throws -> AnthropicLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: [.completion, .tools, .thinking],
            systemPrompt: prompt,
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

    @Test("successful stream emits exactly one .complete then finishes")
    func successPathEmitsExactlyOneComplete() async throws {
        let source = StubStreamSource(events: [
            .success(.contentDelta("hello ")),
            .success(.contentDelta("world")),
            .success(.messageDelta(usage: AnthropicUsage(inputTokens: 1, outputTokens: 2), stopReason: "end_turn")),
            .success(.messageStop),
        ])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let completes = results.filter { if case .complete = $0 { return true } else { return false } }
        #expect(completes.count == 1)
        if case .complete(let final) = completes[0] {
            #expect(final.content == "hello world")
            #expect(final.metadata?.finishReason == FinishReason.stop.rawValue)
        }
    }

    @Test("cancelling the consuming Task surfaces CancellationError; no synthesized .complete")
    func cancellationSurfacesCancellationError() async throws {
        let adapter = try await makeAdapter(streamSource: NeverEndingStreamSource(firstEvent: .contentDelta("partial")))
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let collector = Task<(results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?), Never> {
            await self.consume(stream)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        collector.cancel()
        let (results, terminal) = await collector.value

        for result in results {
            if case .complete = result {
                Issue.record("contract violation: synthesized .complete on cancellation")
            }
        }
        if let terminal {
            #expect(terminal is CancellationError)
        }
    }

    @Test("unknown stream error wraps as LLMError.networkError(_:)")
    func unknownStreamErrorWrapsAsNetworkError() async throws {
        struct BoundaryError: Error {}
        let source = StubStreamSource(events: [.failure(BoundaryError())])
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
        let source = StubStreamSource(events: [.failure(LLMError.timeout)])
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

    @Test("thinking-only delta emits a .reasoning streaming fragment")
    func thinkingDeltaEmitsReasoningFragment() async throws {
        let source = StubStreamSource(events: [
            .success(.thinkingDelta("deliberating", signature: "sig")),
            .success(.messageDelta(usage: nil, stopReason: "end_turn")),
            .success(.messageStop),
        ])
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

    @Test("tool start and input deltas accumulate on .complete")
    func toolDeltasAccumulateOnComplete() async throws {
        let source = StubStreamSource(events: [
            .success(.toolCallStarted(id: "toolu_1", name: "search", contentIndex: 0)),
            .success(.toolInputDelta(id: nil, name: nil, fragment: "{\"q\":\"")),
            .success(.toolInputDelta(id: nil, name: nil, fragment: "rust\"}")),
            .success(.messageDelta(usage: nil, stopReason: "tool_use")),
            .success(.messageStop),
        ])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        guard let last = results.last, case .complete(let final) = last else {
            Issue.record("expected terminal .complete, got results: \(results)")
            return
        }
        #expect(final.toolCalls.count == 1)
        #expect(final.toolCalls.first?.id == "toolu_1")
        #expect(final.toolCalls.first?.name == "search")
        #expect(final.metadata?.finishReason == FinishReason.toolCalls.rawValue)
    }

    @Test("SSE error event surfaces as LLMError.invalidResponse without .complete")
    func sseErrorEventMapsToInvalidResponse() async throws {
        let source = StubStreamSource(events: [.success(.error("model overloaded"))])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (results, terminal) = await consume(stream)

        guard let llmError = terminal as? LLMError, case .invalidResponse(let message) = llmError else {
            Issue.record("expected .invalidResponse terminal, got \(String(describing: terminal))")
            return
        }
        #expect(message.contains("model overloaded"))
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: synthesized .complete on failure path")
            }
        }
    }

    @Test("stream request uses /v1/messages and maps thinkingConfig into payload")
    func streamMapsMessagesURLAndThinking() async throws {
        let source = CapturingStreamSource()
        let adapter = try await makeAdapter(streamSource: source)
        let config = LLMRequestConfig(
            maxTokens: 1024,
            additionalParameters: .object([
                "thinkingConfig": .object([
                    "level": .string("high"),
                    "budgetTokens": .integer(2048),
                ]),
            ])
        )
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: config)
        _ = await consume(stream)

        let url = try #require(source.observedAPIURL())
        #expect(url.absoluteString.hasSuffix("/v1/messages"))
        let body = try #require(source.observedRequestBody())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 2048)
    }
}
