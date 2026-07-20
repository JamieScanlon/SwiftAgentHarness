import Foundation
import EasyJSON
import SwiftAgentKit

enum PromptCacheKnobKey {
    static let mode = "promptCacheMode"
    static let stablePrefixMessageCount = "promptCacheStablePrefixMessageCount"
    static let breakpoints = "promptCacheBreakpoints"
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
    public var breakpoints: [PromptCacheBreakpointCandidate]
    public var stablePrefixTokenEstimate: Int?

    public init(
        mode: PromptCacheMode,
        stablePrefixMessageCount: Int? = nil,
        breakpoints: [PromptCacheBreakpointCandidate] = [],
        stablePrefixTokenEstimate: Int? = nil
    ) {
        self.mode = mode
        self.stablePrefixMessageCount = stablePrefixMessageCount
        self.breakpoints = breakpoints
        self.stablePrefixTokenEstimate = stablePrefixTokenEstimate
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
        let candidates = PromptCacheBreakpointCandidates.build(input: input)
        let selection = ProviderRuntimeHooks.selectPromptCacheBreakpoints(
            candidates: candidates,
            binding: input.binding,
            capabilities: input.modelCapabilities,
            strategy: strategy,
            messages: input.messages
        )
        guard selection.mode != .none, !selection.breakpoints.isEmpty else {
            return PromptCachePlan(mode: .none, stablePrefixMessageCount: nil)
        }
        var messageCount = selection.stablePrefixMessageCount
        if strategy == .conservative, let count = messageCount {
            messageCount = min(count, 3)
        }
        return PromptCachePlan(
            mode: selection.mode,
            stablePrefixMessageCount: messageCount,
            breakpoints: selection.breakpoints,
            stablePrefixTokenEstimate: selection.stablePrefixTokenEstimate
        )
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
        let expectsRead = PromptCacheExpectsReadGate.evaluate(
            plan: plan,
            lastLLMDate: PromptCachePlanningMetadata.lastLLMDate(from: config.additionalParameters),
            binding: binding,
            referenceInstant: ContextCacheTTLPruning.deterministicReferenceInstant(from: messages),
            messages: messages
        )
        let response = try await ModelInvocationTaskContext.$promptCacheExpectsRead.withValue(expectsRead) {
            try await base.send(messages, config: configured)
        }
        await emitPromptCacheTelemetry(
            plan: plan,
            messages: messages,
            response: response,
            transportKnobApplied: transportKnobApplied(plan: plan)
        )
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
        let expectsRead = PromptCacheExpectsReadGate.evaluate(
            plan: plan,
            lastLLMDate: PromptCachePlanningMetadata.lastLLMDate(from: config.additionalParameters),
            binding: binding,
            referenceInstant: ContextCacheTTLPruning.deterministicReferenceInstant(from: messages),
            messages: messages
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await ModelInvocationTaskContext.$promptCacheExpectsRead.withValue(expectsRead) {
                        let upstream = base.stream(messages, config: configured)
                        for try await event in upstream {
                            if case .complete(let final) = event {
                                await emitPromptCacheTelemetry(
                                    plan: plan,
                                    messages: messages,
                                    response: final,
                                    transportKnobApplied: transportKnobApplied(plan: plan)
                                )
                            }
                            continuation.yield(event)
                        }
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
        if !plan.breakpoints.isEmpty {
            object[PromptCacheKnobKey.breakpoints] = .array(
                plan.breakpoints.map { candidate in
                    .object([
                        "kind": .string(candidate.kind.rawValue),
                        "estimatedPrefixTokens": .integer(candidate.estimatedPrefixTokens),
                    ])
                }
            )
        }
        return LLMRequestConfig(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            availableTools: config.availableTools,
            toolParameterSchemasByName: config.toolParameterSchemasByName,
            toolSchemaStrictByName: config.toolSchemaStrictByName,
            additionalParameters: .object(object)
        )
    }

    private func transportKnobApplied(plan: PromptCachePlan) -> Bool {
        guard plan.mode != .none else { return false }
        return binding.modelProtocol == .lmStudio
    }

    private func providerSupportsNativePromptCache() -> Bool {
        let capabilities = Set(modelCapabilities)
        if capabilities.contains(.promptCacheEphemeral) || capabilities.contains(.promptCachePersistent) {
            return true
        }
        return ProviderRuntimeHooks.cacheTtlEligibility(binding: binding) != .none
    }

    private func providerAppliedPromptCache(
        plan: PromptCachePlan,
        reported: NormalizedUsage?,
        transportKnobApplied: Bool
    ) -> Bool {
        let reportedCacheActivity = (reported?.cacheReadTokens ?? 0) + (reported?.cacheWriteTokens ?? 0) > 0
        return reportedCacheActivity || (transportKnobApplied && plan.mode != .none)
    }

    private func unexpectedCacheWrite(
        plan: PromptCachePlan,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        valuesAreProviderReported: Bool
    ) -> Bool {
        guard plan.mode != .none, valuesAreProviderReported else { return false }
        guard ModelInvocationTaskContext.promptCacheExpectsRead == true else { return false }
        return (cacheWriteTokens ?? 0) > 0 && (cacheReadTokens ?? 0) == 0
    }

    private func emitPromptCacheTelemetry(
        plan: PromptCachePlan,
        messages: [Message],
        response: LLMResponse,
        transportKnobApplied: Bool
    ) async {
        guard let attemptObserver else { return }
        let reported = CanonicalUsageExtraction.from(metadata: response.metadata)
        let valuesAreProviderReported = CanonicalUsageExtraction.valuesAreProviderReported(from: response.metadata)
            || reported?.cacheReadTokens != nil
            || reported?.cacheWriteTokens != nil
        let estimatedStablePrefixTokens = plan.stablePrefixTokenEstimate
            ?? PromptCacheBreakpointCandidates.stablePrefixTokenEstimate(from: plan.breakpoints)
            ?? 0
        let inputTokens = reported?.inputTokens ?? response.metadata?.promptTokens ?? estimateTokens(in: messages)
        let cachedInputTokens = reported?.cacheReadTokens ?? estimatedCachedInputFallback(
            providerApplied: providerAppliedPromptCache(
                plan: plan,
                reported: reported,
                transportKnobApplied: transportKnobApplied
            ),
            inputTokens: inputTokens,
            estimatedStablePrefixTokens: estimatedStablePrefixTokens
        )
        let cacheWriteTokens = reported?.cacheWriteTokens ?? estimatedCacheWriteFallback(
            providerApplied: transportKnobApplied,
            plan: plan,
            estimatedStablePrefixTokens: estimatedStablePrefixTokens
        )
        let estimatedSavingsUSD: Double? = {
            guard let cachedTokens = cachedInputTokens,
                  let inputRate = modelCost?.inputPer1MUSD,
                  let cachedRate = modelCost?.cachedInputPer1MUSD,
                  inputRate > cachedRate
            else { return nil }
            return max(0, (inputRate - cachedRate) * (Double(cachedTokens) / 1_000_000))
        }()
        let providerApplied = providerAppliedPromptCache(
            plan: plan,
            reported: reported,
            transportKnobApplied: transportKnobApplied
        )
        let unexpectedWrite = unexpectedCacheWrite(
            plan: plan,
            cacheReadTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            valuesAreProviderReported: valuesAreProviderReported
        )
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
                promptCacheProviderSupportsNative: providerSupportsNativePromptCache(),
                promptCacheProviderApplied: providerApplied,
                promptCacheEstimatedInputTokens: inputTokens,
                promptCacheEstimatedCachedInputTokens: cachedInputTokens,
                promptCacheEstimatedCacheWriteTokens: cacheWriteTokens,
                promptCacheEstimatedSavingsUSD: estimatedSavingsUSD,
                promptCacheValuesAreProviderReported: valuesAreProviderReported,
                promptCacheUnexpectedCacheWrite: unexpectedWrite ? true : nil
            )
        )
    }

    private func estimatedCachedInputFallback(
        providerApplied: Bool,
        inputTokens: Int,
        estimatedStablePrefixTokens: Int
    ) -> Int? {
        guard providerApplied else { return nil }
        return min(inputTokens, estimatedStablePrefixTokens)
    }

    private func estimatedCacheWriteFallback(
        providerApplied: Bool,
        plan: PromptCachePlan,
        estimatedStablePrefixTokens: Int
    ) -> Int? {
        guard providerApplied, plan.mode == .persistent else { return nil }
        return estimatedStablePrefixTokens
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

