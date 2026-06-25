import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Contract tests for ``LMStudioLLM`` streaming behavior. Drive the adapter via
/// the new ``LMStudioStreamSourcing`` test seam so we can script SSE payloads
/// without standing up a real `RestAPIManager`.
@Suite("LMStudioLLM stream contract")
struct LMStudioLLMStreamContractTests {

    // MARK: - Stub stream source

    private struct StubLMStudioStreamSource: LMStudioStreamSourcing {
        let payloads: [[String: any Sendable]]
        func sseStream(
            baseURL: URL,
            endpoint: String,
            parameters: [String: any Sendable],
            sseTimeoutInterval: TimeInterval,
            logger: Logger?
        ) async -> AsyncStream<[String: any Sendable]> {
            let payloads = self.payloads
            return AsyncStream { continuation in
                Task {
                    for payload in payloads {
                        continuation.yield(payload)
                    }
                    continuation.finish()
                }
            }
        }
    }

    private struct EmptyLMStudioStreamSource: LMStudioStreamSourcing {
        func sseStream(
            baseURL: URL,
            endpoint: String,
            parameters: [String: any Sendable],
            sseTimeoutInterval: TimeInterval,
            logger: Logger?
        ) async -> AsyncStream<[String: any Sendable]> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
    }

    private struct NeverEndingLMStudioStreamSource: LMStudioStreamSourcing {
        let firstPayload: [String: any Sendable]
        func sseStream(
            baseURL: URL,
            endpoint: String,
            parameters: [String: any Sendable],
            sseTimeoutInterval: TimeInterval,
            logger: Logger?
        ) async -> AsyncStream<[String: any Sendable]> {
            let firstPayload = self.firstPayload
            return AsyncStream { continuation in
                Task {
                    continuation.yield(firstPayload)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    continuation.finish()
                }
            }
        }
    }

    private actor CapturingLMStudioStreamSource: LMStudioStreamSourcing {
        private var lastParameters: [String: any Sendable]?

        func sseStream(
            baseURL: URL,
            endpoint: String,
            parameters: [String: any Sendable],
            sseTimeoutInterval: TimeInterval,
            logger: Logger?
        ) async -> AsyncStream<[String: any Sendable]> {
            let _ = (baseURL, endpoint, sseTimeoutInterval, logger)
            lastParameters = parameters
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        func observedParameters() -> [String: any Sendable]? {
            return lastParameters
        }
    }

    // MARK: - Helpers

    private func makeAdapter(streamSource: any LMStudioStreamSourcing) async throws -> LMStudioLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return LMStudioLLM(
            model: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools, .promptCacheEphemeral],
            systemPrompt: prompt,
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

    // MARK: - SSE error event maps to LLMError.invalidResponse

    @Test("SSE event:error chunk surfaces as LLMError.invalidResponse with message preserved")
    func sseErrorEventMapsToInvalidResponse() async throws {
        let errorPayload: [String: any Sendable] = [
            "_sse_event": "error",
            "error": ["message": "model not loaded"] as [String: any Sendable]
        ]
        let source = StubLMStudioStreamSource(payloads: [errorPayload])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let (results, terminal) = await consume(stream)
        guard let llmError = terminal as? LLMError else {
            Issue.record("expected LLMError terminal, got \(String(describing: terminal))")
            return
        }
        switch llmError {
        case .invalidResponse(let message):
            #expect(message.contains("LM Studio SSE error"))
            #expect(message.contains("model not loaded"))
        default:
            Issue.record("expected .invalidResponse, got \(llmError)")
        }
        // No .complete on the failure path.
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: synthesized .complete on failure path")
            }
        }
    }

    @Test("regression (CR-C): SSE error event with zero data chunks surfaces provider message, not generic stream-ended text")
    func sseErrorZeroDataChunksSurfacesProviderMessage() async throws {
        // Reproduces the LM Studio failure: a single SSE error event (no data chunks) carrying
        // the jinja render error. The surfaced detail must include the provider message rather than
        // the generic "stream ended without receiving any data chunks".
        let jinjaError = "Error rendering prompt with jinja template: \"No user query found in messages.\""
        let errorPayload: [String: any Sendable] = [
            "_sse_event": "error",
            "error": ["message": jinjaError] as [String: any Sendable]
        ]
        let source = StubLMStudioStreamSource(payloads: [errorPayload])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))

        let (_, terminal) = await consume(stream)
        guard let err = terminal as? LLMError, case .invalidResponse(let message) = err else {
            Issue.record("expected .invalidResponse terminal, got \(String(describing: terminal))")
            return
        }
        #expect(message.contains(jinjaError))
        #expect(!message.contains("stream ended without receiving any data chunks"))
    }

    @Test("payload-level error envelope (no _sse_event) also maps to LLMError.invalidResponse")
    func payloadErrorEnvelopeMapsToInvalidResponse() async throws {
        let errorPayload: [String: any Sendable] = [
            "error": ["type": "rate_limit", "message": "rate exceeded"] as [String: any Sendable]
        ]
        let source = StubLMStudioStreamSource(payloads: [errorPayload])
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (_, terminal) = await consume(stream)
        guard let err = terminal as? LLMError, case .invalidResponse(let message) = err else {
            Issue.record("expected .invalidResponse terminal, got \(String(describing: terminal))")
            return
        }
        #expect(message.contains("rate exceeded"))
    }

    // MARK: - No-valid-choices guard

    @Test("stream that ends with zero chunks surfaces as LLMError.invalidResponse")
    func emptyStreamSurfacesAsInvalidResponse() async throws {
        let adapter = try await makeAdapter(streamSource: EmptyLMStudioStreamSource())
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (_, terminal) = await consume(stream)
        guard let err = terminal as? LLMError, case .invalidResponse(let message) = err else {
            Issue.record("expected .invalidResponse terminal, got \(String(describing: terminal))")
            return
        }
        #expect(message.contains("LM Studio stream ended without receiving any data chunks"))
    }

    @Test("stream that ends with chunks but no usable choices surfaces as LLMError.invalidResponse")
    func choicelessChunksSurfaceAsInvalidResponse() async throws {
        // Three chunks that all have no `choices`, just a stray field.
        let payloads: [[String: any Sendable]] = [
            ["other": "noise"],
            ["other": "more-noise"],
            ["other": "final"]
        ]
        let source = StubLMStudioStreamSource(payloads: payloads)
        let adapter = try await makeAdapter(streamSource: source)
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig(maxTokens: 1024))
        let (_, terminal) = await consume(stream)
        guard let err = terminal as? LLMError, case .invalidResponse(let message) = err else {
            Issue.record("expected .invalidResponse terminal, got \(String(describing: terminal))")
            return
        }
        #expect(message.contains("LM Studio stream ended after"))
        #expect(message.contains("none contained valid choices"))
    }

    // MARK: - Successful stream emits exactly one .complete

    @Test("successful stream yields exactly one .complete then finishes")
    func successPathEmitsExactlyOneComplete() async throws {
        let chunkA: [String: any Sendable] = [
            "choices": [
                ["index": 0, "delta": ["content": "hello "] as [String: any Sendable]] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let chunkB: [String: any Sendable] = [
            "choices": [
                ["index": 0, "delta": ["content": "world"] as [String: any Sendable]] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let final: [String: any Sendable] = [
            "choices": [
                [
                    "index": 0,
                    "delta": ["content": ""] as [String: any Sendable],
                    "finish_reason": "stop"
                ] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let source = StubLMStudioStreamSource(payloads: [chunkA, chunkB, final])
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

    // MARK: - Cancellation

    @Test("cancellation surfaces CancellationError; no .complete yielded")
    func cancellationSurfacesCancellationError() async throws {
        let firstPayload: [String: any Sendable] = [
            "choices": [
                ["index": 0, "delta": ["content": "partial"] as [String: any Sendable]] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let adapter = try await makeAdapter(streamSource: NeverEndingLMStudioStreamSource(firstPayload: firstPayload))
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

    @Test("stream request maps response format, parallel tool calls, and reasoning effort knobs")
    func streamMapsRequestKnobsIntoPayload() async throws {
        let source = CapturingLMStudioStreamSource()
        let adapter = try await makeAdapter(streamSource: source)
        let config = LLMRequestConfig(
            maxTokens: 1024,
            additionalParameters: .object([
                "responseFormat": .string("json_object"),
                "parallelToolCalls": .boolean(true),
                "thinkingConfig": .object(["level": .string("high")]),
                PromptCacheKnobKey.mode: .string("ephemeral"),
                PromptCacheKnobKey.stablePrefixMessageCount: .integer(3),
            ])
        )
        let stream = adapter.stream([Message(id: UUID(), role: .user, content: "hi")], config: config)
        _ = await consume(stream)

        let params = try #require(await source.observedParameters())
        let responseFormat = params["response_format"] as? [String: any Sendable]
        #expect(responseFormat?["type"] as? String == "json_object")
        #expect(params["parallel_tool_calls"] as? Bool == true)
        #expect(params["reasoning_effort"] as? String == "high")
        let promptCache = params["prompt_cache"] as? [String: any Sendable]
        #expect(promptCache?["mode"] as? String == "ephemeral")
        #expect(promptCache?["stable_prefix_messages"] as? Int == 3)
    }
}
