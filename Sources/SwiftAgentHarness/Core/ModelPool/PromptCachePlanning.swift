import Foundation
import EasyJSON
import SwiftAgentKit

enum PromptCacheKnobKey {
    static let mode = "promptCacheMode"
    static let stablePrefixMessageCount = "promptCacheStablePrefixMessageCount"
}

public enum PromptCachePolicy: Sendable, Equatable {
    case disabled
    case enabled(strategy: PromptCacheStrategy = .automatic)
}

public enum PromptCacheStrategy: Sendable, Equatable {
    case automatic
    case conservative
}

public enum PromptCacheMode: Sendable, Equatable {
    case none
    case ephemeral
    case persistent
}

public struct PromptCachePlan: Sendable, Equatable {
    public var mode: PromptCacheMode
    public var stablePrefixMessageCount: Int?

    public init(mode: PromptCacheMode, stablePrefixMessageCount: Int? = nil) {
        self.mode = mode
        self.stablePrefixMessageCount = stablePrefixMessageCount
    }
}

public struct PromptCachePlanningInput: Sendable {
    public var modelID: UUID
    public var binding: ProviderBinding
    public var modelCapabilities: [LLMCapability]
    public var messages: [Message]
    public var config: LLMRequestConfig
    public var policy: PromptCachePolicy

    public init(
        modelID: UUID,
        binding: ProviderBinding,
        modelCapabilities: [LLMCapability],
        messages: [Message],
        config: LLMRequestConfig,
        policy: PromptCachePolicy
    ) {
        self.modelID = modelID
        self.binding = binding
        self.modelCapabilities = modelCapabilities
        self.messages = messages
        self.config = config
        self.policy = policy
    }
}

public protocol PromptCachePlanning: Sendable {
    func plan(for input: PromptCachePlanningInput) -> PromptCachePlan
}

public struct PromptCachePlanningMetricsSnapshot: Sendable, Equatable {
    public var totalPlans: Int
    public var nonePlans: Int
    public var ephemeralPlans: Int
    public var persistentPlans: Int

    public init(totalPlans: Int = 0, nonePlans: Int = 0, ephemeralPlans: Int = 0, persistentPlans: Int = 0) {
        self.totalPlans = totalPlans
        self.nonePlans = nonePlans
        self.ephemeralPlans = ephemeralPlans
        self.persistentPlans = persistentPlans
    }
}

public actor PromptCachePlanningMetricsStore {
    public static let shared = PromptCachePlanningMetricsStore()
    private var snapshot = PromptCachePlanningMetricsSnapshot()

    public init() {}

    public func record(mode: PromptCacheMode) {
        snapshot.totalPlans += 1
        switch mode {
        case .none:
            snapshot.nonePlans += 1
        case .ephemeral:
            snapshot.ephemeralPlans += 1
        case .persistent:
            snapshot.persistentPlans += 1
        }
    }

    public func current() -> PromptCachePlanningMetricsSnapshot {
        snapshot
    }
}

public struct NoOpPromptCachePlanner: PromptCachePlanning {
    public init() {}

    public func plan(for input: PromptCachePlanningInput) -> PromptCachePlan {
        let _ = input
        return PromptCachePlan(mode: .none, stablePrefixMessageCount: nil)
    }
}

public struct CapabilityDrivenPromptCachePlanner: PromptCachePlanning {
    public init() {}

    public func plan(for input: PromptCachePlanningInput) -> PromptCachePlan {
        guard case .enabled(let strategy) = input.policy else {
            return PromptCachePlan(mode: .none, stablePrefixMessageCount: nil)
        }
        let capabilities = Set(input.modelCapabilities)
        let supportsPersistent = capabilities.contains(.promptCachePersistent)
        let supportsEphemeral = supportsPersistent || capabilities.contains(.promptCacheEphemeral)
        guard supportsEphemeral else {
            return PromptCachePlan(mode: .none, stablePrefixMessageCount: nil)
        }
        let stablePrefix = stablePrefixMessageCount(messages: input.messages, strategy: strategy)
        guard let stablePrefix, stablePrefix > 0 else {
            return PromptCachePlan(mode: .none, stablePrefixMessageCount: nil)
        }
        switch strategy {
        case .automatic:
            if supportsPersistent && stablePrefix >= 3 {
                return PromptCachePlan(mode: .persistent, stablePrefixMessageCount: stablePrefix)
            }
            return PromptCachePlan(mode: .ephemeral, stablePrefixMessageCount: stablePrefix)
        case .conservative:
            return PromptCachePlan(mode: .ephemeral, stablePrefixMessageCount: min(stablePrefix, 3))
        }
    }

    private func stablePrefixMessageCount(messages: [Message], strategy: PromptCacheStrategy) -> Int? {
        guard !messages.isEmpty else { return nil }
        var count = 0
        for message in messages {
            switch message.role {
            case .system, .user:
                count += 1
            case .assistant, .tool:
                break
            }
            if message.role == .assistant || message.role == .tool {
                break
            }
        }
        guard count >= 2 else { return nil }
        let cap = strategy == .conservative ? 4 : 8
        return min(count, cap)
    }
}

struct PromptCachePlanningLLM: LLMProtocol, AdapterAuthProbing {
    let base: any LLMProtocol
    let modelID: UUID
    let binding: ProviderBinding
    let modelCapabilities: [LLMCapability]
    let modelCost: ModelCostBudget?
    let policy: PromptCachePolicy
    let planner: any PromptCachePlanning
    let attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?

    var currentState: LLMRuntimeState { base.currentState }
    var stateUpdates: AsyncStream<LLMRuntimeState> { base.stateUpdates }
    func getModelName() -> String { base.getModelName() }
    func getCapabilities() -> [LLMCapability] { base.getCapabilities() }
    func getRequestFeatures() -> ModelRequestFeatures { base.getRequestFeatures() }
    func validateAuth() async -> Bool {
        guard let probe = base as? any AdapterAuthProbing else { return true }
        return await probe.validateAuth()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let plan = planner.plan(for: PromptCachePlanningInput(
            modelID: modelID,
            binding: binding,
            modelCapabilities: modelCapabilities,
            messages: messages,
            config: config,
            policy: policy
        ))
        await PromptCachePlanningMetricsStore.shared.record(mode: plan.mode)
        let configured = apply(plan: plan, to: config)
        let response = try await base.send(messages, config: configured)
        await emitPromptCacheTelemetry(plan: plan, messages: messages, response: response, providerApplied: providerAppliesPromptCache(plan: plan))
        return response
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await base.generateImage(config)
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let plan = planner.plan(for: PromptCachePlanningInput(
            modelID: modelID,
            binding: binding,
            modelCapabilities: modelCapabilities,
            messages: messages,
            config: config,
            policy: policy
        ))
        Task {
            await PromptCachePlanningMetricsStore.shared.record(mode: plan.mode)
        }
        let configured = apply(plan: plan, to: config)
        let upstream = base.stream(messages, config: configured)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in upstream {
                        if case .complete(let final) = event {
                            await emitPromptCacheTelemetry(
                                plan: plan,
                                messages: messages,
                                response: final,
                                providerApplied: providerAppliesPromptCache(plan: plan)
                            )
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func apply(plan: PromptCachePlan, to config: LLMRequestConfig) -> LLMRequestConfig {
        var object: [String: JSON] = [:]
        if let additional = config.additionalParameters, case .object(let existing) = additional {
            object = existing
        }
        switch plan.mode {
        case .none:
            object[PromptCacheKnobKey.mode] = .string("none")
        case .ephemeral:
            object[PromptCacheKnobKey.mode] = .string("ephemeral")
        case .persistent:
            object[PromptCacheKnobKey.mode] = .string("persistent")
        }
        if let stablePrefix = plan.stablePrefixMessageCount {
            object[PromptCacheKnobKey.stablePrefixMessageCount] = .integer(stablePrefix)
        }
        return LLMRequestConfig(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            availableTools: config.availableTools,
            additionalParameters: .object(object)
        )
    }

    private func providerAppliesPromptCache(plan: PromptCachePlan) -> Bool {
        guard plan.mode != .none else { return false }
        return binding.modelProtocol == .lmStudio
    }

    private func emitPromptCacheTelemetry(
        plan: PromptCachePlan,
        messages: [Message],
        response: LLMResponse,
        providerApplied: Bool
    ) async {
        guard let attemptObserver else { return }
        let stablePrefixCount = max(0, plan.stablePrefixMessageCount ?? 0)
        let estimatedInputTokens = response.metadata?.promptTokens ?? estimateTokens(in: messages)
        let estimatedStablePrefixTokens = estimateTokens(in: Array(messages.prefix(stablePrefixCount)))
        let estimatedCachedInputTokens = providerApplied ? min(estimatedInputTokens, estimatedStablePrefixTokens) : nil
        let estimatedCacheWriteTokens = (providerApplied && plan.mode == .persistent) ? estimatedStablePrefixTokens : nil
        let estimatedSavingsUSD: Double? = {
            guard providerApplied,
                  let cachedTokens = estimatedCachedInputTokens,
                  let inputRate = modelCost?.inputPer1MUSD,
                  let cachedRate = modelCost?.cachedInputPer1MUSD,
                  inputRate > cachedRate else {
                return nil
            }
            return max(0, (inputRate - cachedRate) * (Double(cachedTokens) / 1_000_000))
        }()
        await attemptObserver(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: ModelInvocationTaskContext.callID,
                kind: .promptCache,
                outcome: .observed,
                providerID: binding.providerId,
                endpointModelID: binding.endpointModelId,
                promptCacheMode: modeRawValue(plan.mode),
                promptCacheStablePrefixMessageCount: plan.stablePrefixMessageCount,
                promptCacheProviderSupportsNative: binding.modelProtocol == .lmStudio,
                promptCacheProviderApplied: providerApplied,
                promptCacheEstimatedInputTokens: estimatedInputTokens,
                promptCacheEstimatedCachedInputTokens: estimatedCachedInputTokens,
                promptCacheEstimatedCacheWriteTokens: estimatedCacheWriteTokens,
                promptCacheEstimatedSavingsUSD: estimatedSavingsUSD
            )
        )
    }

    private func estimateTokens(in messages: [Message]) -> Int {
        max(0, messages.reduce(0) { partialResult, message in
            partialResult + Int(ceil(Double(message.content.count) / 4.0))
        })
    }

    private func modeRawValue(_ mode: PromptCacheMode) -> String {
        switch mode {
        case .none:
            return "none"
        case .ephemeral:
            return "ephemeral"
        case .persistent:
            return "persistent"
        }
    }
}

