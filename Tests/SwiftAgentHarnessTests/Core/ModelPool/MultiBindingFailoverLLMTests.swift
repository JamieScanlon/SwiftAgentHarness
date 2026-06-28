import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor MultiBindingAttemptCollector {
    var rows: [ModelCallAttemptObservation] = []

    func append(_ row: ModelCallAttemptObservation) {
        rows.append(row)
    }
}

private actor BindingScriptedLLM: LLMProtocol {
    enum StreamScript: Sendable {
        case success(partials: [String], final: String)
        case throwBeforeFirstChunk(Error)
        case yieldThenThrow(firstPartial: String, error: Error)
    }

    private var sendQueue: [Result<LLMResponse, Error>]
    private var imageQueue: [Result<ImageGenerationResponse, Error>]
    private var streamQueue: [StreamScript]
    private(set) var sendCalls: Int = 0
    private(set) var imageCalls: Int = 0
    private(set) var streamCalls: Int = 0
    private let requestFeatures: ModelRequestFeatures

    init(
        sendQueue: [Result<LLMResponse, Error>] = [.success(LLMResponse(content: "ok", toolCalls: []))],
        imageQueue: [Result<ImageGenerationResponse, Error>] = [.success(ImageGenerationResponse(images: []))],
        streamQueue: [StreamScript] = [],
        requestFeatures: ModelRequestFeatures = .unknown
    ) {
        self.sendQueue = sendQueue
        self.imageQueue = imageQueue
        self.streamQueue = streamQueue
        self.requestFeatures = requestFeatures
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "binding-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { requestFeatures }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        sendCalls += 1
        guard !sendQueue.isEmpty else { return LLMResponse(content: "ok", toolCalls: []) }
        switch sendQueue.removeFirst() {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        imageCalls += 1
        guard !imageQueue.isEmpty else { return ImageGenerationResponse(images: []) }
        switch imageQueue.removeFirst() {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            Task {
                let script = await self.popStreamScript()
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

    func observed() -> (send: Int, image: Int, stream: Int) {
        (sendCalls, imageCalls, streamCalls)
    }
}

private actor AuthProbeBindingLLM: LLMProtocol, AdapterAuthProbing {
    private let allowAuth: Bool
    private(set) var sendCalls: Int = 0

    init(allowAuth: Bool) {
        self.allowAuth = allowAuth
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "auth-probe-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func validateAuth() async -> Bool { allowAuth }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        sendCalls += 1
        return LLMResponse(content: "ok", toolCalls: [])
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        return ImageGenerationResponse(images: [])
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            continuation.finish()
        }
    }

    func observedSendCalls() -> Int { sendCalls }
}

@Suite("MultiBindingFailoverLLM")
struct MultiBindingFailoverLLMTests {
    private static func binding(_ endpoint: String, priority: Int) -> ProviderBinding {
        ProviderBinding(
            providerId: "provider-\(endpoint)",
            modelProtocol: .openAIAPI,
            endpointModelId: endpoint,
            serverURL: URL(string: "http://localhost:1")!,
            priority: priority
        )
    }

    @Test("primary binding success does not fallback")
    func primarySuccessNoFallback() async throws {
        let primary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "primary", toolCalls: []))])
        let secondary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "secondary", toolCalls: []))])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "primary")
        #expect(await primary.observed().send == 1)
        #expect(await secondary.observed().send == 0)
    }

    @Test("transient send error fails over to next binding")
    func transientSendFallsOver() async throws {
        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let secondary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "secondary", toolCalls: []))])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "secondary")
        #expect(await primary.observed().send == 1)
        #expect(await secondary.observed().send == 1)
    }

    @Test("exhausted failover propagates last error")
    func exhaustedFailoverPropagates() async {
        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let secondary = BindingScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        await #expect(throws: LLMError.self) {
            _ = try await llm.send([], config: LLMRequestConfig())
        }
    }

    @Test("stream retries across bindings only before first partial")
    func streamPreFirstChunkFailoverOnly() async {
        let primary = BindingScriptedLLM(streamQueue: [
            .throwBeforeFirstChunk(LLMError.timeout),
        ])
        let secondary = BindingScriptedLLM(streamQueue: [
            .success(partials: ["hello "], final: "hello world"),
        ])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        var partials: [String] = []
        var final: String?
        do {
            for try await result in llm.stream([], config: LLMRequestConfig()) {
                switch result {
                case .stream(let p): partials.append(p.content)
                case .complete(let f): final = f.content
                }
            }
        } catch {
            Issue.record("Did not expect stream failure: \(error)")
        }
        #expect(partials == ["hello "])
        #expect(final == "hello world")
    }

    @Test("stream does not fail over after first partial")
    func streamNoFailoverAfterPartial() async {
        let primary = BindingScriptedLLM(streamQueue: [
            .yieldThenThrow(firstPartial: "p", error: LLMError.timeout),
        ])
        let secondary = BindingScriptedLLM(streamQueue: [
            .success(partials: ["unused"], final: "unused"),
        ])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        var partials: [String] = []
        var thrown: Error?
        do {
            for try await result in llm.stream([], config: LLMRequestConfig()) {
                if case .stream(let p) = result { partials.append(p.content) }
            }
        } catch {
            thrown = error
        }
        #expect(partials == ["p"])
        #expect(thrown is LLMError)
        #expect(await secondary.observed().stream == 0)
    }

    @Test("getRequestFeatures forwards from highest-priority binding")
    func getRequestFeaturesForwardsFromFirstBinding() {
        let features = ModelRequestFeatures(
            streaming: true,
            responseFormats: [.jsonObject],
            parallelToolCalls: .uncapped,
            reasoningEfforts: [.high]
        )
        let primary = BindingScriptedLLM(requestFeatures: features)
        let secondary = BindingScriptedLLM()
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            }
        )
        #expect(llm.getRequestFeatures() == features)
    }

    @Test("auth probe skips failed binding and advances")
    func authProbeSkipsFailedBinding() async throws {
        let denied = AuthProbeBindingLLM(allowAuth: false)
        let allowed = AuthProbeBindingLLM(allowAuth: true)
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? denied : allowed
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "ok")
        #expect(await denied.observedSendCalls() == 0)
        #expect(await allowed.observedSendCalls() == 1)
    }

    @Test("attempt observer captures auth skip and binding failover continuation")
    func attemptObserverCapturesFailover() async throws {
        let collector = MultiBindingAttemptCollector()
        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let secondary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "secondary", toolCalls: []))])
        let modelID = UUID()
        let callID = UUID()
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            },
            modelID: modelID,
            attemptObserver: { observation in
                await collector.append(observation)
            }
        )
        let response = await ModelInvocationTaskContext.$callID.withValue(callID) {
            try? await llm.send([], config: LLMRequestConfig())
        }
        #expect(response?.content == "secondary")
        let rows = await collector.rows
        let hasContinuedPrimary = rows.contains { row in
            row.kind == .bindingFailover && row.outcome == .continued && row.endpointModelID == "a"
        }
        let hasSucceededSecondary = rows.contains { row in
            row.kind == .bindingFailover && row.outcome == .succeeded && row.endpointModelID == "b"
        }
        #expect(hasContinuedPrimary)
        #expect(hasSucceededSecondary)
    }

    @Test("secondary binding failure does not emit spurious succeeded telemetry")
    func secondaryFailureOmitsPrematureSucceeded() async throws {
        let collector = MultiBindingAttemptCollector()
        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.timeout)])
        let secondary = BindingScriptedLLM(sendQueue: [.failure(LLMError.modelNotFound("missing"))])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.binding("a", priority: 0), Self.binding("b", priority: 1)],
            makeBindingLLM: { binding in
                binding.endpointModelId == "a" ? primary : secondary
            },
            modelID: UUID(),
            attemptObserver: { observation in
                await collector.append(observation)
            }
        )
        await #expect(throws: LLMError.self) {
            _ = try await llm.send([], config: LLMRequestConfig())
        }
        let rows = await collector.rows
        #expect(!rows.contains { row in
            row.kind == .bindingFailover && row.outcome == .succeeded && row.endpointModelID == "b"
        })
        #expect(rows.contains { row in
            row.kind == .bindingFailover && row.outcome == .terminalFailure && row.endpointModelID == "b"
        })
    }

    @Test("auth probe remains visible through retry prompt-cache and response-cache wrappers")
    func authProbeDelegatesThroughWrappers() async throws {
        let deniedBase = AuthProbeBindingLLM(allowAuth: false)
        let allowedBase = AuthProbeBindingLLM(allowAuth: true)
        let modelID = UUID()
        let bindingA = Self.binding("a", priority: 0)
        let bindingB = Self.binding("b", priority: 1)
        let llm = MultiBindingFailoverLLM(
            bindings: [bindingA, bindingB],
            makeBindingLLM: { binding in
                let base: any LLMProtocol = (binding.endpointModelId == "a") ? deniedBase : allowedBase
                let promptWrapped = PromptCachePlanningLLM(
                    base: base,
                    modelID: modelID,
                    binding: binding,
                    modelCapabilities: [.completion],
                    modelCost: nil,
                    policy: .enabled(strategy: .automatic),
                    planner: NoOpPromptCachePlanner(),
                    attemptObserver: nil
                )
                let cacheWrapped = ResponseCachingLLM(
                    base: promptWrapped,
                    store: ResponseCacheStore(),
                    modelID: modelID,
                    providerScopeKey: "scope-\(binding.endpointModelId)",
                    policy: .enabled(maxEntries: 8, ttlSeconds: nil, stablePrefixMessageCount: nil)
                )
                return RetryingLLM(
                    base: cacheWrapped,
                    policy: FailoverPolicy(maxRetries: 1),
                    logger: nil
                )
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "ok")
        #expect(await deniedBase.observedSendCalls() == 0)
        #expect(await allowedBase.observedSendCalls() == 1)
    }

    private static func anthropicBinding(_ endpoint: String, priority: Int) -> ProviderBinding {
        ProviderBinding(
            providerId: "anthropic-\(endpoint)",
            modelProtocol: .anthropic,
            endpointModelId: endpoint,
            serverURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            priority: priority
        )
    }

    @Test("heterogeneous anthropic then openAI binding failover on primary modelNotFound")
    func heterogeneousBindingFailover() async throws {
        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.modelNotFound("claude"))])
        let secondary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = MultiBindingFailoverLLM(
            bindings: [
                Self.anthropicBinding("claude", priority: 0),
                Self.binding("gpt-proxy", priority: 10),
            ],
            makeBindingLLM: { binding in
                binding.modelProtocol == .anthropic ? primary : secondary
            }
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "fallback")
        #expect(await primary.sendCalls == 1)
        #expect(await secondary.sendCalls == 1)
    }

    @Test("heterogeneous failover replays anthropic thinking without signature on openAI target")
    func heterogeneousFailoverTransformsForeignThinking() async throws {
        HarnessMessageEnvelopeStore.resetForTesting()
        let assistantID = UUID()
        let assistant = Message(
            id: assistantID,
            role: .assistant,
            content: "prior answer",
            timestamp: Date(),
            toolCalls: []
        )
        HarnessMessageEnvelopeStore.store(
            HarnessMessageEnvelope(
                message: assistant,
                contentBlocks: [.thinking(text: "chain", signature: "sig-foreign"), .text("prior answer")]
            )
        )
        let openAIBinding = Self.binding("gpt-proxy", priority: 10)
        let history: [Message] = [
            Message(id: UUID(), role: .user, content: "question", timestamp: Date(), toolCalls: []),
            assistant,
        ]
        let replaySafe = ProviderRuntimeHooks.transformMessages(
            history,
            binding: openAIBinding,
            compat: ProviderModelCompat(supportsEagerToolInputStreaming: false)
        )
        #expect(replaySafe.count == 2)
        #expect(replaySafe[1].content.contains("chain"))
        #expect(!replaySafe[1].content.contains("sig-foreign"))

        let primary = BindingScriptedLLM(sendQueue: [.failure(LLMError.modelNotFound("claude"))])
        let secondary = BindingScriptedLLM(sendQueue: [.success(LLMResponse(content: "fallback", toolCalls: []))])
        let llm = MultiBindingFailoverLLM(
            bindings: [Self.anthropicBinding("claude", priority: 0), openAIBinding],
            makeBindingLLM: { binding in
                binding.modelProtocol == .anthropic ? primary : secondary
            }
        )
        let response = try await llm.send(replaySafe, config: LLMRequestConfig())
        #expect(response.content == "fallback")
    }
}

@Suite("BindingFailoverClassifier")
struct BindingFailoverClassifierTests {
    @Test("transient classes advance to next binding")
    func transientAdvances() {
        #expect(BindingFailoverClassifier.classify(LLMError.timeout) == .tryNextBinding)
        #expect(BindingFailoverClassifier.classify(LLMError.rateLimitExceeded) == .tryNextBinding)
    }

    @Test("model binding-scoped terminal classes can advance")
    func bindingScopedCanAdvance() {
        #expect(BindingFailoverClassifier.classify(LLMError.modelNotFound("missing")) == .tryNextBinding)
        #expect(BindingFailoverClassifier.classify(LLMError.unsupportedCapability(.imageGeneration)) == .tryNextBinding)
    }

    @Test("cancellation and auth are terminal")
    func cancellationAndAuthTerminal() {
        #expect(BindingFailoverClassifier.classify(CancellationError()) == .terminal)
        #expect(BindingFailoverClassifier.classify(LLMError.authenticationFailed) == .terminal)
    }
}

