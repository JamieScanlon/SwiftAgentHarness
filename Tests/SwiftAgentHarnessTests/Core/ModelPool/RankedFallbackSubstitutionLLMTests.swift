import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor RankedAttemptCollector {
    var rows: [ModelCallAttemptObservation] = []

    func append(_ row: ModelCallAttemptObservation) {
        rows.append(row)
    }
}

private actor RankedScriptedLLM: LLMProtocol {
    enum StreamScript: Sendable {
        case success(partials: [String], final: String)
        case throwBeforeFirstChunk(Error)
        case yieldThenThrow(firstPartial: String, error: Error)
    }

    private var sendQueue: [Result<LLMResponse, Error>]
    private var streamQueue: [StreamScript]
    private(set) var sendCalls: Int = 0
    private(set) var streamCalls: Int = 0

    init(
        sendQueue: [Result<LLMResponse, Error>] = [.success(LLMResponse(content: "ok", toolCalls: []))],
        streamQueue: [StreamScript] = []
    ) {
        self.sendQueue = sendQueue
        self.streamQueue = streamQueue
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "ranked-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        sendCalls += 1
        guard !sendQueue.isEmpty else { return LLMResponse(content: "ok", toolCalls: []) }
        switch sendQueue.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        return ImageGenerationResponse(images: [])
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            Task {
                let script = await popStreamScript()
                switch script {
                case .none:
                    continuation.finish()
                case .success(let partials, let final):
                    for partial in partials {
                        continuation.yield(.stream(LLMResponse(content: partial, toolCalls: [])))
                    }
                    continuation.yield(.complete(LLMResponse(content: final, toolCalls: [])))
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

    private func popStreamScript() -> StreamScript? {
        streamCalls += 1
        guard !streamQueue.isEmpty else { return nil }
        return streamQueue.removeFirst()
    }

    func observed() -> (send: Int, stream: Int) {
        (sendCalls, streamCalls)
    }
}

@Suite("RankedFallbackSubstitutionLLM")
struct RankedFallbackSubstitutionLLMTests {
    private static func candidate(_ label: String, llm: any LLMProtocol) -> RankedFallbackSubstitutionLLM.Candidate {
        RankedFallbackSubstitutionLLM.Candidate(modelID: UUID(), label: label, llm: llm)
    }

    @Test("primary success does not invoke fallback")
    func primarySuccessNoFallback() async throws {
        let primary = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "primary", toolCalls: []))])
        let fallback = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), Self.candidate("fallback", llm: fallback)]
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "primary")
        #expect(await primary.observed().send == 1)
        #expect(await fallback.observed().send == 0)
    }

    @Test("transient primary failure falls back to ranked alternative")
    func transientFallbackSuccess() async throws {
        let primary = RankedScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let fallback = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), Self.candidate("fallback", llm: fallback)]
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "fallback")
        #expect(await primary.observed().send == 1)
        #expect(await fallback.observed().send == 1)
    }

    @Test("terminal auth failure does not substitute")
    func terminalFailureNoSubstitution() async {
        let primary = RankedScriptedLLM(sendQueue: [.failure(LLMError.authenticationFailed)])
        let fallback = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), Self.candidate("fallback", llm: fallback)]
        )
        await #expect(throws: LLMError.self) {
            _ = try await llm.send([], config: LLMRequestConfig())
        }
        #expect(await fallback.observed().send == 0)
    }

    @Test("stream retries only before first partial")
    func streamRetriesPreFirstChunkOnly() async {
        let primary = RankedScriptedLLM(streamQueue: [.throwBeforeFirstChunk(LLMError.timeout)])
        let fallback = RankedScriptedLLM(streamQueue: [.success(partials: ["hello "], final: "world")])
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), Self.candidate("fallback", llm: fallback)]
        )
        var partials: [String] = []
        var final = ""
        do {
            for try await event in llm.stream([], config: LLMRequestConfig()) {
                switch event {
                case .stream(let p): partials.append(p.content)
                case .complete(let f): final = f.content
                }
            }
        } catch {
            Issue.record("Did not expect stream failure: \(error)")
        }
        #expect(partials == ["hello "])
        #expect(final == "world")
    }

    @Test("cancellation propagates without fallback")
    func cancellationPropagatesWithoutFallback() async {
        let primary = RankedScriptedLLM(sendQueue: [.failure(CancellationError())])
        let fallback = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), Self.candidate("fallback", llm: fallback)]
        )
        await #expect(throws: CancellationError.self) {
            _ = try await llm.send([], config: LLMRequestConfig())
        }
        #expect(await fallback.observed().send == 0)
    }

    @Test("attempt observer emits substitution continuation and success")
    func attemptObserverEmitsSubstitution() async throws {
        let collector = RankedAttemptCollector()
        let primary = RankedScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let fallback = RankedScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let fallbackCandidate = Self.candidate("fallback", llm: fallback)
        let llm = RankedFallbackSubstitutionLLM(
            candidates: [Self.candidate("primary", llm: primary), fallbackCandidate],
            attemptObserver: { observation in
                await collector.append(observation)
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "fallback")
        let rows = await collector.rows
        let hasContinuedFallback = rows.contains { row in
            row.kind == .modelSubstitution && row.outcome == .continued
        }
        let hasSucceededFallback = rows.contains { row in
            row.kind == .modelSubstitution && row.outcome == .succeeded && row.targetModelID == fallbackCandidate.modelID
        }
        #expect(hasContinuedFallback)
        #expect(hasSucceededFallback)
    }
}

