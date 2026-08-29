import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Stub LLM for stream tests. Each entry in `streamScripts` is replayed once per
/// `stream(...)` call (in order), then the script is empty and subsequent calls finish empty.
private actor ScriptedStreamLLM: LLMProtocol {
    enum Script: Sendable {
        /// Yield the given partial(s) then a `.complete`, then finish.
        case successYieldThenComplete(partials: [String], finalText: String)
        /// Yield no partials and throw before any first chunk.
        case throwBeforeFirstChunk(error: Error)
        /// Yield the given first partial, then throw.
        case yieldThenThrow(firstPartial: String, error: Error)
    }

    private var scripts: [Script]
    private(set) var streamCallCount: Int = 0

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }
    nonisolated func getModelName() -> String { "scripted" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        LLMResponse(content: "ignored", toolCalls: [])
    }

    func observedStreamCalls() -> Int { streamCallCount }

    private func nextScript() -> Script? {
        guard !scripts.isEmpty else { return nil }
        return scripts.removeFirst()
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.bumpStreamCallCount()
                let script = await self.nextScript()
                switch script {
                case .none:
                    continuation.finish()
                case .successYieldThenComplete(let partials, let finalText):
                    for partial in partials {
                        continuation.yield(.stream(LLMResponse(content: partial, toolCalls: [])))
                    }
                    continuation.yield(.complete(LLMResponse(content: finalText, toolCalls: [])))
                    continuation.finish()
                case .throwBeforeFirstChunk(let error):
                    continuation.finish(throwing: error)
                case .yieldThenThrow(let firstPartial, let error):
                    continuation.yield(.stream(LLMResponse(content: firstPartial, toolCalls: [])))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func bumpStreamCallCount() {
        streamCallCount += 1
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

@Suite("RetryingLLM.stream pre-first-chunk retries")
struct RetryingLLMStreamTests {
    private static let fastPolicy = FailoverPolicy(
        maxRetries: 3,
        baseDelay: 0.001,
        maxDelay: 0.005,
        jitterFraction: 0.0
    )

    private static func collect(_ stream: AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>) async throws -> (partials: [String], final: String?) {
        var partials: [String] = []
        var final: String?
        for try await result in stream {
            switch result {
            case .stream(let p):
                partials.append(p.content)
            case .complete(let f):
                final = f.content
            }
        }
        return (partials, final)
    }

    @Test("Pre-first-chunk transient error retries; consumer sees one successful stream")
    func preFirstChunkTransientRetries() async throws {
        let stub = ScriptedStreamLLM(scripts: [
            .throwBeforeFirstChunk(error: LLMError.timeout),
            .successYieldThenComplete(partials: ["hello "], finalText: "hello world"),
        ])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        let result = try await Self.collect(retry.stream([], config: LLMRequestConfig()))

        #expect(result.partials == ["hello "])
        #expect(result.final == "hello world")
        let calls = await stub.observedStreamCalls()
        #expect(calls == 2)
    }

    @Test("First partial yielded then transient error: consumer sees partial then error, no retry")
    func firstPartialThenTransientNoRetry() async throws {
        let stub = ScriptedStreamLLM(scripts: [
            .yieldThenThrow(firstPartial: "abc", error: LLMError.timeout),
            // Second script would only run if a retry happened — must NOT.
            .successYieldThenComplete(partials: ["xyz"], finalText: "xyz"),
        ])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        var partials: [String] = []
        var thrown: Error?
        do {
            for try await result in retry.stream([], config: LLMRequestConfig()) {
                if case .stream(let p) = result { partials.append(p.content) }
            }
        } catch {
            thrown = error
        }

        #expect(partials == ["abc"])
        #expect(thrown is LLMError)
        let calls = await stub.observedStreamCalls()
        #expect(calls == 1) // no retry once consumer saw first chunk
    }

    @Test("Degenerate stream with no partials retries: classified transient")
    func degenerateStreamPreFirstChunkRetries() async throws {
        let stub = ScriptedStreamLLM(scripts: [
            .throwBeforeFirstChunk(error: DegenerateStreamError(
                kind: .noEvents,
                provider: "Anthropic",
                detail: "Anthropic stream completed with no SSE events"
            )),
            .successYieldThenComplete(partials: ["hello "], finalText: "hello world"),
        ])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        let result = try await Self.collect(retry.stream([], config: LLMRequestConfig()))

        #expect(result.final == "hello world")
        let calls = await stub.observedStreamCalls()
        #expect(calls == 2)
    }

    @Test("Degenerate stream after a partial does not retry: the firstYielded guard outranks transient")
    func degenerateStreamAfterPartialDoesNotRetry() async throws {
        let stub = ScriptedStreamLLM(scripts: [
            .yieldThenThrow(firstPartial: "I can see the ", error: DegenerateStreamError(
                kind: .announcedToolCallLost,
                provider: "Anthropic",
                detail: "Anthropic stream announced 1 tool_use content block(s) but assembled 0 tool call(s)"
            )),
            // Would only run on a retry — re-issuing here would duplicate the emitted text.
            .successYieldThenComplete(partials: ["duplicate"], finalText: "duplicate"),
        ])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        var partials: [String] = []
        var thrown: Error?
        do {
            for try await result in retry.stream([], config: LLMRequestConfig()) {
                if case .stream(let p) = result { partials.append(p.content) }
            }
        } catch {
            thrown = error
        }

        #expect(partials == ["I can see the "])
        #expect(thrown is DegenerateStreamError)
        let calls = await stub.observedStreamCalls()
        #expect(calls == 1)
    }

    @Test("Terminal pre-first-chunk error does not retry")
    func terminalPreFirstChunkNoRetry() async throws {
        let stub = ScriptedStreamLLM(scripts: [
            .throwBeforeFirstChunk(error: LLMError.invalidRequest("bad")),
            .successYieldThenComplete(partials: ["unused"], finalText: "unused"),
        ])
        let retry = RetryingLLM(base: stub, policy: Self.fastPolicy, logger: nil)

        var thrown: Error?
        do {
            for try await _ in retry.stream([], config: LLMRequestConfig()) {}
        } catch {
            thrown = error
        }
        #expect(thrown is LLMError)
        let calls = await stub.observedStreamCalls()
        #expect(calls == 1)
    }

    @Test("Transient errors past maxRetries surface the last error")
    func transientExhaustedSurfacesError() async throws {
        let policy = FailoverPolicy(maxRetries: 2, baseDelay: 0.001, maxDelay: 0.002, jitterFraction: 0.0)
        let stub = ScriptedStreamLLM(scripts: [
            .throwBeforeFirstChunk(error: LLMError.timeout),
            .throwBeforeFirstChunk(error: LLMError.timeout),
            .throwBeforeFirstChunk(error: LLMError.timeout),
        ])
        let retry = RetryingLLM(base: stub, policy: policy, logger: nil)

        var thrown: Error?
        do {
            for try await _ in retry.stream([], config: LLMRequestConfig()) {}
        } catch {
            thrown = error
        }
        #expect(thrown is LLMError)
        let calls = await stub.observedStreamCalls()
        #expect(calls == 3) // initial + 2 retries
    }

    @Test("Cancellation stops the retry loop (no further scripts consumed)")
    func cancellationStopsRetries() async throws {
        // Slow backoff so the wrapper is sleeping between attempts when we cancel.
        let policy = FailoverPolicy(maxRetries: 50, baseDelay: 1.0, maxDelay: 5.0, jitterFraction: 0.0)
        let stub = ScriptedStreamLLM(scripts: Array(
            repeating: ScriptedStreamLLM.Script.throwBeforeFirstChunk(error: LLMError.timeout),
            count: 50
        ))
        let retry = RetryingLLM(base: stub, policy: policy, logger: nil)

        let task = Task {
            // Either clean exit or CancellationError counts as cancellation; what matters is
            // that retries stop and the outer iteration unblocks.
            var thrown: Error?
            do {
                for try await _ in retry.stream([], config: LLMRequestConfig()) {}
            } catch {
                thrown = error
            }
            return thrown
        }

        // Let one attempt fail and the wrapper start sleeping.
        try await Task.sleep(nanoseconds: 50_000_000)
        let callsBeforeCancel = await stub.observedStreamCalls()
        task.cancel()
        _ = await task.value

        // Give the wrapper a moment to react to cancellation.
        try await Task.sleep(nanoseconds: 20_000_000)
        let callsAfterCancel = await stub.observedStreamCalls()

        // The wrapper should have stopped retrying — at most one more attempt may have
        // been in flight when cancel was observed.
        #expect(callsAfterCancel <= callsBeforeCancel + 1,
                "Expected retries to stop after cancellation; before=\(callsBeforeCancel) after=\(callsAfterCancel)")
        #expect(callsAfterCancel < 50, "Should not have run all 50 scripts after cancellation")
    }

    @Test("RetryingLLMFactory.wrap returns base unchanged when maxRetries == 0")
    func factoryBypassesWhenZeroRetries() async throws {
        let stub = ScriptedStreamLLM(scripts: [.successYieldThenComplete(partials: ["x"], finalText: "x")])
        let wrapped = RetryingLLMFactory.wrap(baseLLM: stub, policy: FailoverPolicy(maxRetries: 0), logger: nil)
        // Same instance reference would require identity; instead, sanity-check the type.
        #expect(!(wrapped is RetryingLLM))
    }

    @Test("RetryingLLMFactory.wrap returns RetryingLLM when maxRetries > 0")
    func factoryWrapsWhenRetriesEnabled() async throws {
        let stub = ScriptedStreamLLM(scripts: [.successYieldThenComplete(partials: ["x"], finalText: "x")])
        let wrapped = RetryingLLMFactory.wrap(baseLLM: stub, policy: FailoverPolicy(maxRetries: 1), logger: nil)
        #expect(wrapped is RetryingLLM)
    }
}
