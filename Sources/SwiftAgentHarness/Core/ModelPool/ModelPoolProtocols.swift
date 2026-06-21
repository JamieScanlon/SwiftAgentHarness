import Foundation
import Logging
import SwiftAgentKit

// MARK: - Phase 0 seam: LLM construction without branching on protocol in HarnessRuntimeSession

/// Builds the provider-specific base ``LLMProtocol`` for a resolved ``Model`` (pool-owned adapter surface).
///
/// `conversationID` is threaded through so the factory can construct per-call wrappers
/// (`BudgetEnforcingLLM`, future per-conversation accumulators) that need conversation
/// context. Pass `nil` for one-off calls outside a chat (for example, future sub-agent
/// invocations).
public protocol ModelLLMFactoring: Sendable {
    func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
    ) -> any LLMProtocol
}

// MARK: - Phase 5: concurrency cap at pool boundary

public enum ModelRequestPriority: Sendable, Equatable {
    case foreground
    case background
}

public enum ModelSubstitutionPolicy: Sendable, Equatable {
    case disabled
    case enabled(maxFallbackCandidates: Int = 2)
}

public struct ModelCallReservation: Sendable, Equatable {
    public var modelID: UUID
    public var priority: ModelRequestPriority
    public var conversationID: UUID?
    public var credentialKey: String?
    public var estimatedTotalTokens: Int?

    public init(
        modelID: UUID,
        priority: ModelRequestPriority,
        conversationID: UUID? = nil,
        credentialKey: String? = nil,
        estimatedTotalTokens: Int? = nil
    ) {
        self.modelID = modelID
        self.priority = priority
        self.conversationID = conversationID
        self.credentialKey = credentialKey
        self.estimatedTotalTokens = estimatedTotalTokens
    }
}

public struct ModelCallAcquisition: Sendable, Equatable {
    public var modelID: UUID
    public var credentialKey: String?
    public var reservedRequestUnits: Int
    public var reservedTokenUnits: Int

    public init(
        modelID: UUID,
        credentialKey: String? = nil,
        reservedRequestUnits: Int = 0,
        reservedTokenUnits: Int = 0
    ) {
        self.modelID = modelID
        self.credentialKey = credentialKey
        self.reservedRequestUnits = reservedRequestUnits
        self.reservedTokenUnits = reservedTokenUnits
    }
}

public protocol ModelCallScheduling: Sendable {
    func acquire(for modelID: UUID, priority: ModelRequestPriority) async
    func release(for modelID: UUID) async
    func acquire(reservation: ModelCallReservation) async -> ModelCallAcquisition
    func release(acquisition: ModelCallAcquisition) async
    /// Per-model in-flight count (powers ``ModelStatePayload/inFlightCount``). Conformers that don't
    /// track per-model load should return `0`.
    func inFlightCount(for modelID: UUID) async -> Int
}

public extension ModelCallScheduling {
    func acquire(reservation: ModelCallReservation) async -> ModelCallAcquisition {
        await acquire(for: reservation.modelID, priority: reservation.priority)
        return ModelCallAcquisition(
            modelID: reservation.modelID,
            credentialKey: reservation.credentialKey
        )
    }

    func release(acquisition: ModelCallAcquisition) async {
        await release(for: acquisition.modelID)
    }
}

public extension ModelLLMFactoring {
    func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?
    ) -> any LLMProtocol {
        makeBaseLLM(
            model: model,
            providerBindings: providerBindings,
            conversationID: conversationID,
            ownerAccountID: ownerAccountID,
            systemPrompt: systemPrompt,
            logger: logger,
            attemptObserver: nil
        )
    }

    func substitutionPolicy() -> ModelSubstitutionPolicy { .disabled }
}

/// Default no-op scheduler (tests or opt-out).
public struct NoOpModelCallScheduler: ModelCallScheduling {
    public init() {}

    public func acquire(for modelID: UUID, priority: ModelRequestPriority) async {}

    public func release(for modelID: UUID) async {}

    public func inFlightCount(for modelID: UUID) async -> Int { 0 }
}

// MARK: - Phase 4: per-call lifecycle (observability)

public enum ModelInvocationPhase: String, Sendable, Codable {
    case queued
    case dispatching
    case connecting
    case streaming
    case toolCalling
    case completing
    case done
    case errored
    case cancelled
}

public enum ModelCallAttemptKind: String, Sendable, Codable, Equatable {
    case retry
    case bindingFailover
    case modelSubstitution
    case authProbeSkip
    case promptCache
}

public enum ModelCallAttemptOutcome: String, Sendable, Codable, Equatable {
    case continued
    case succeeded
    case terminalFailure
    case skipped
    case observed
}

public struct ModelCallAttemptObservation: Sendable, Equatable {
    public var modelID: UUID
    public var callID: UUID?
    public var kind: ModelCallAttemptKind
    public var outcome: ModelCallAttemptOutcome
    public var errorClass: String?
    public var errorCode: String?
    public var providerID: String?
    public var endpointModelID: String?
    public var targetModelID: UUID?
    public var promptCacheMode: String?
    public var promptCacheStablePrefixMessageCount: Int?
    public var promptCacheProviderSupportsNative: Bool?
    public var promptCacheProviderApplied: Bool?
    public var promptCacheEstimatedInputTokens: Int?
    public var promptCacheEstimatedCachedInputTokens: Int?
    public var promptCacheEstimatedCacheWriteTokens: Int?
    public var promptCacheEstimatedSavingsUSD: Double?
    public var latencyMs: Double?
    public var observedAt: Date

    public init(
        modelID: UUID,
        callID: UUID?,
        kind: ModelCallAttemptKind,
        outcome: ModelCallAttemptOutcome,
        errorClass: String? = nil,
        errorCode: String? = nil,
        providerID: String? = nil,
        endpointModelID: String? = nil,
        targetModelID: UUID? = nil,
        promptCacheMode: String? = nil,
        promptCacheStablePrefixMessageCount: Int? = nil,
        promptCacheProviderSupportsNative: Bool? = nil,
        promptCacheProviderApplied: Bool? = nil,
        promptCacheEstimatedInputTokens: Int? = nil,
        promptCacheEstimatedCachedInputTokens: Int? = nil,
        promptCacheEstimatedCacheWriteTokens: Int? = nil,
        promptCacheEstimatedSavingsUSD: Double? = nil,
        latencyMs: Double? = nil,
        observedAt: Date = Date()
    ) {
        self.modelID = modelID
        self.callID = callID
        self.kind = kind
        self.outcome = outcome
        self.errorClass = errorClass
        self.errorCode = errorCode
        self.providerID = providerID
        self.endpointModelID = endpointModelID
        self.targetModelID = targetModelID
        self.promptCacheMode = promptCacheMode
        self.promptCacheStablePrefixMessageCount = promptCacheStablePrefixMessageCount
        self.promptCacheProviderSupportsNative = promptCacheProviderSupportsNative
        self.promptCacheProviderApplied = promptCacheProviderApplied
        self.promptCacheEstimatedInputTokens = promptCacheEstimatedInputTokens
        self.promptCacheEstimatedCachedInputTokens = promptCacheEstimatedCachedInputTokens
        self.promptCacheEstimatedCacheWriteTokens = promptCacheEstimatedCacheWriteTokens
        self.promptCacheEstimatedSavingsUSD = promptCacheEstimatedSavingsUSD
        self.latencyMs = latencyMs
        self.observedAt = observedAt
    }
}

public protocol ModelInvocationCoordinating: Sendable {
    func recordTransition(modelID: UUID, phase: ModelInvocationPhase, callID: UUID?) async
}

/// Pool lifecycle + stream telemetry used by ``SchedulingLLM`` and ``LifecycleReportingLLM``.
public protocol ModelInvocationLifecycleTracking: ModelInvocationCoordinating, Sendable {
    /// Begins a per-model call. `conversationID` (when supplied) lets the coordinator fan
    /// derived ``ModelStatePayload`` updates onto `conversation/{id}/events` and
    /// `conversation/{id}/state` in addition to `model/{id}/state`.
    func beginCall(modelID: UUID, conversationID: UUID?, logicalRequestID: UUID?) async -> UUID
    func currentCallID(for modelID: UUID) async -> UUID?
    func endCall(modelID: UUID, callID: UUID) async
    func recordStreamPartial(modelID: UUID, callID: UUID?, partial: LLMResponse) async
    /// Schedules a one-shot refresh so ``thinking`` becomes true after 200ms in ``connecting`` without new deltas.
    func scheduleConnectingThinkingRefresh(modelID: UUID) async
    /// Records a terminal error so communication aggregates can classify outcomes
    /// (for example, recent rate-limit windows) before `.errored` publish.
    func recordError(modelID: UUID, callID: UUID?, error: Error) async
    /// Captures completion metadata before `.done` so aggregates can derive throughput.
    func recordResponseMetrics(modelID: UUID, callID: UUID?, response: LLMResponse) async
    /// Records retry/failover/substitution attempt telemetry for call-level observability.
    func recordAttemptObservation(_ observation: ModelCallAttemptObservation) async
}

extension ModelInvocationLifecycleTracking {
    /// Convenience for utility / non-conversation LLMs (compaction, summarization, tests).
    public func beginCall(modelID: UUID) async -> UUID {
        await beginCall(modelID: modelID, conversationID: nil, logicalRequestID: nil)
    }

    public func beginCall(modelID: UUID, conversationID: UUID?) async -> UUID {
        await beginCall(modelID: modelID, conversationID: conversationID, logicalRequestID: nil)
    }

    public func recordError(modelID: UUID, callID: UUID?, error: Error) async {
        let _ = (modelID, callID, error)
    }

    public func recordResponseMetrics(modelID: UUID, callID: UUID?, response: LLMResponse) async {
        let _ = (modelID, callID, response)
    }

    public func recordAttemptObservation(_ observation: ModelCallAttemptObservation) async {
        let _ = observation
    }
}
