import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private final class PromptPlanningCounter: @unchecked Sendable {
    private var lock = NSLock()
    private var value: Int = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    func observed() -> Int {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

private struct CountingPromptPlanner: PromptCachePlanning {
    let counter: PromptPlanningCounter
    func plan(for input: PromptCachePlanningInput) -> PromptCachePlan {
        let _ = input
        counter.increment()
        return PromptCachePlan(mode: .none)
    }
}

private actor PromptPlanningLLMStub: LLMProtocol {
    private var lastConfig: LLMRequestConfig?
    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "prompt-planning-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures {
        ModelRequestFeatures(
            streaming: true,
            responseFormats: [.jsonObject],
            parallelToolCalls: .uncapped,
            reasoningEfforts: [.medium]
        )
    }
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        lastConfig = config
        return LLMResponse(content: "ok", toolCalls: [])
    }
    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        return ImageGenerationResponse(images: [])
    }
    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observedLastConfig() -> LLMRequestConfig? {
        lastConfig
    }
}

private actor PromptCacheAttemptCollector {
    private(set) var rows: [ModelCallAttemptObservation] = []
    func record(_ row: ModelCallAttemptObservation) {
        rows.append(row)
    }
}

@Suite("Prompt cache planning seam")
struct PromptCachePlanningTests {
    @Test("planning wrapper invokes planner on send")
    func planningWrapperInvokesPlanner() async throws {
        let counter = PromptPlanningCounter()
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-x",
            serverURL: URL(string: "https://example.com")!,
            priority: 0
        )
        let base = PromptPlanningLLMStub()
        let wrapper = PromptCachePlanningLLM(
            base: base,
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.promptCacheEphemeral, .completion],
            modelCost: nil,
            policy: .enabled(strategy: .automatic),
            planner: CountingPromptPlanner(counter: counter),
            attemptObserver: nil
        )
        _ = try await wrapper.send([], config: LLMRequestConfig())
        #expect(counter.observed() == 1)
        #expect(wrapper.getRequestFeatures().responseFormats.contains(.jsonObject))
        let observedConfig = await base.observedLastConfig()
        guard let additional = observedConfig?.additionalParameters,
              case .object(let object) = additional else {
            Issue.record("Expected prompt cache plan keys in additionalParameters")
            return
        }
        guard case .string(let mode)? = object[PromptCacheKnobKey.mode] else {
            Issue.record("Expected prompt cache mode key")
            return
        }
        #expect(mode == "none")
        let metrics = await PromptCachePlanningMetricsStore.shared.current()
        #expect(metrics.totalPlans >= 1)
    }

    @Test("capability-driven planner selects persistent when capability present")
    func capabilityDrivenPlannerSelectsPersistent() async {
        let planner = CapabilityDrivenPromptCachePlanner()
        let binding = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "model-x",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 0
        )
        let input = PromptCachePlanningInput(
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.completion, .promptCachePersistent],
            messages: [
                Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: [])
            ],
            config: LLMRequestConfig(),
            policy: .enabled(strategy: .automatic)
        )
        let plan = planner.plan(for: input)
        #expect(plan.mode == .persistent)
        #expect((plan.stablePrefixMessageCount ?? 0) >= 2)
    }

    @Test("stable prefix counting does not require Memory Context harness message")
    func stablePrefixWithoutMemoryContextMessage() async {
        let planner = CapabilityDrivenPromptCachePlanner()
        let binding = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "model-x",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 0
        )
        let input = PromptCachePlanningInput(
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.completion, .promptCachePersistent],
            messages: [
                Message(id: UUID(), role: .system, content: "canonical system", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: []),
            ],
            config: LLMRequestConfig(),
            policy: .enabled(strategy: .automatic)
        )
        let plan = planner.plan(for: input)
        #expect(plan.mode == .persistent)
        #expect((plan.stablePrefixMessageCount ?? 0) >= 2)
        #expect(!input.messages.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.memoryContext) }))
    }

    @Test("capability-driven planner disables when unsupported")
    func capabilityDrivenPlannerDisablesWithoutCapability() async {
        let planner = CapabilityDrivenPromptCachePlanner()
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "model-x",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let input = PromptCachePlanningInput(
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.completion],
            messages: [
                Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: [])
            ],
            config: LLMRequestConfig(),
            policy: .enabled(strategy: .automatic)
        )
        let plan = planner.plan(for: input)
        #expect(plan.mode == .none)
        #expect(plan.stablePrefixMessageCount == nil)
    }

    @Test("planning wrapper emits prompt-cache telemetry on send")
    func planningWrapperEmitsPromptCacheTelemetry() async throws {
        let binding = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "model-x",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 0
        )
        let collector = PromptCacheAttemptCollector()
        let base = PromptPlanningLLMStub()
        let wrapper = PromptCachePlanningLLM(
            base: base,
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.completion, .promptCachePersistent],
            modelCost: ModelCostBudget(inputPer1MUSD: 2, outputPer1MUSD: 5, cachedInputPer1MUSD: 0.5),
            policy: .enabled(strategy: .automatic),
            planner: CapabilityDrivenPromptCachePlanner(),
            attemptObserver: { observation in
                await collector.record(observation)
            }
        )
        _ = try await wrapper.send(
            [
                Message(id: UUID(), role: .system, content: "system baseline", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "user request", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "stable context", timestamp: Date(), toolCalls: [])
            ],
            config: LLMRequestConfig()
        )
        let rows = await collector.rows
        let hasPromptCacheTelemetry = rows.contains { row in
            row.kind == .promptCache &&
                row.outcome == .observed &&
                row.promptCacheMode == "persistent" &&
                row.promptCacheProviderApplied == true &&
                (row.promptCacheEstimatedCachedInputTokens ?? 0) > 0
        }
        #expect(hasPromptCacheTelemetry)
    }
}

