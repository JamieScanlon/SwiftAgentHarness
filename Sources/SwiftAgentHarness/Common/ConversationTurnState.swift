import Foundation

/// High-level agentic tool-loop phase for UI and wire protocol (mirrors SwiftAgentKit `AgenticLoopState`).
public enum ConversationAgenticPhase: String, Codable, Sendable, Equatable {
    case idle
    case started
    case llmCall
    /// One model generation finished (observability); distinct from starting the next inner step.
    case llmGenerationCompleted
    case waitingForToolExecution
    case executingTools
    case betweenIterations
    case completed
    case failed
    case maxIterationsReached
}

/// Shared LLM instance phase for UI and wire protocol (mirrors SwiftAgentKit `LLMRuntimeState`).
public enum ConversationLLMRuntimePhase: String, Codable, Sendable, Equatable {
    case idleReady
    case idleCompleted
    case generatingReasoning
    case generatingResponding
    case failed
}

/// Per-request LLM phase for UI and wire protocol (mirrors SwiftAgentKit `LLMRequestState` without associated values).
public enum ConversationLLMRequestPhase: String, Codable, Sendable, Equatable {
    case idle
    case queued
    case active
    case generating
    case streaming
    case completed
    case failed
    case cancelled
}

/// Combined orchestration snapshot for one user send (LLM instance + per-call request + agentic tool loop).
public struct ConversationOrchestrationState: Codable, Sendable, Equatable {
    public var llmRuntimePhase: ConversationLLMRuntimePhase
    public var llmRuntimeFailureDetail: String?
    public var agenticPhase: ConversationAgenticPhase
    public var llmRequestPhase: ConversationLLMRequestPhase?

    /// Model context window size in tokens when known (e.g. orchestrator / Ollama `num_ctx`).
    public var contextLimitTokens: Int?
    /// Estimated remaining capacity in the context window after the last LLM response, when known.
    public var remainingContextTokens: Int?
    /// Last reported prompt (input) token count from the provider, when known.
    public var promptTokens: Int?
    /// When `true`, plan.md contains at least one blocked task (`[x]`); auto-continue pauses until the plan is updated.
    public var planHasBlockedTasks: Bool
    /// When `true`, plan.md has task lines and every task is complete (`[/]`) with none blocked—auto-continue has no remaining work.
    public var planAllTasksComplete: Bool
    /// Monotonic generation from SwiftAgentKit’s ``OrchestrationSnapshotEvent/generation`` when the snapshot came from ``orchestrationSnapshotUpdates``; `nil` for legacy payloads or auxiliary server emits (e.g. context token refresh). Clients may ignore stale frames when both sides carry a generation.
    public var orchestrationGeneration: UInt64?
    /// Harness-style labels when the server enables optional harness wire fields; `nil` when disabled or absent.
    public var harness: HarnessOrchestrationSupplement?
    /// Identifier for the current user send / streaming orchestration run when known (`nil` when idle).
    public var currentRunID: UUID?

    public init(
        llmRuntimePhase: ConversationLLMRuntimePhase = .idleReady,
        llmRuntimeFailureDetail: String? = nil,
        agenticPhase: ConversationAgenticPhase,
        llmRequestPhase: ConversationLLMRequestPhase? = nil,
        contextLimitTokens: Int? = nil,
        remainingContextTokens: Int? = nil,
        promptTokens: Int? = nil,
        planHasBlockedTasks: Bool = false,
        planAllTasksComplete: Bool = false,
        orchestrationGeneration: UInt64? = nil,
        harness: HarnessOrchestrationSupplement? = nil,
        currentRunID: UUID? = nil
    ) {
        self.llmRuntimePhase = llmRuntimePhase
        self.llmRuntimeFailureDetail = llmRuntimeFailureDetail
        self.agenticPhase = agenticPhase
        self.llmRequestPhase = llmRequestPhase
        self.contextLimitTokens = contextLimitTokens
        self.remainingContextTokens = remainingContextTokens
        self.promptTokens = promptTokens
        self.planHasBlockedTasks = planHasBlockedTasks
        self.planAllTasksComplete = planAllTasksComplete
        self.orchestrationGeneration = orchestrationGeneration
        self.harness = harness
        self.currentRunID = currentRunID
    }

    /// Backward-compatible decode for payloads without LLM runtime fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llmRuntimePhase = try c.decodeIfPresent(ConversationLLMRuntimePhase.self, forKey: .llmRuntimePhase) ?? .idleReady
        llmRuntimeFailureDetail = try c.decodeIfPresent(String.self, forKey: .llmRuntimeFailureDetail)
        agenticPhase = try c.decode(ConversationAgenticPhase.self, forKey: .agenticPhase)
        llmRequestPhase = try c.decodeIfPresent(ConversationLLMRequestPhase.self, forKey: .llmRequestPhase)
        contextLimitTokens = try c.decodeIfPresent(Int.self, forKey: .contextLimitTokens)
        remainingContextTokens = try c.decodeIfPresent(Int.self, forKey: .remainingContextTokens)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        planHasBlockedTasks = try c.decodeIfPresent(Bool.self, forKey: .planHasBlockedTasks) ?? false
        planAllTasksComplete = try c.decodeIfPresent(Bool.self, forKey: .planAllTasksComplete) ?? false
        orchestrationGeneration = try c.decodeIfPresent(UInt64.self, forKey: .orchestrationGeneration)
        harness = try c.decodeIfPresent(HarnessOrchestrationSupplement.self, forKey: .harness)
        currentRunID = try c.decodeIfPresent(UUID.self, forKey: .currentRunID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(llmRuntimePhase, forKey: .llmRuntimePhase)
        try c.encodeIfPresent(llmRuntimeFailureDetail, forKey: .llmRuntimeFailureDetail)
        try c.encode(agenticPhase, forKey: .agenticPhase)
        try c.encodeIfPresent(llmRequestPhase, forKey: .llmRequestPhase)
        try c.encodeIfPresent(contextLimitTokens, forKey: .contextLimitTokens)
        try c.encodeIfPresent(remainingContextTokens, forKey: .remainingContextTokens)
        try c.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try c.encode(planHasBlockedTasks, forKey: .planHasBlockedTasks)
        try c.encode(planAllTasksComplete, forKey: .planAllTasksComplete)
        try c.encodeIfPresent(orchestrationGeneration, forKey: .orchestrationGeneration)
        try c.encodeIfPresent(harness, forKey: .harness)
        try c.encodeIfPresent(currentRunID, forKey: .currentRunID)
    }

    private enum CodingKeys: String, CodingKey {
        case llmRuntimePhase, llmRuntimeFailureDetail, agenticPhase, llmRequestPhase
        case contextLimitTokens, remainingContextTokens, promptTokens
        case planHasBlockedTasks, planAllTasksComplete
        case orchestrationGeneration
        case harness
        case currentRunID
    }
}

extension ConversationOrchestrationState {
    /// Phases and run identity that drive UI/wire status; excludes token counters and ``orchestrationGeneration``.
    public func hasSameWireOrchestrationPhases(as other: ConversationOrchestrationState) -> Bool {
        llmRuntimePhase == other.llmRuntimePhase
            && llmRuntimeFailureDetail == other.llmRuntimeFailureDetail
            && agenticPhase == other.agenticPhase
            && llmRequestPhase == other.llmRequestPhase
            && currentRunID == other.currentRunID
            && planHasBlockedTasks == other.planHasBlockedTasks
            && planAllTasksComplete == other.planAllTasksComplete
            && harness == other.harness
    }

    /// Rough ordering for LLM / request / agentic phases when deciding whether a wire snapshot regressed mid-turn.
    public var wireOrchestrationActivityRank: Int {
        var rank = 0
        switch llmRuntimePhase {
        case .generatingReasoning, .generatingResponding: rank += 100
        case .failed: rank += 50
        case .idleReady: rank += 10
        case .idleCompleted: rank += 0
        }
        switch llmRequestPhase {
        case .streaming: rank += 80
        case .generating: rank += 70
        case .active: rank += 60
        case .queued: rank += 40
        case .completed, .failed, .cancelled: rank += 5
        case .idle, .none: rank += 0
        }
        switch agenticPhase {
        case .executingTools, .llmCall: rank += 60
        case .waitingForToolExecution, .betweenIterations, .started: rank += 40
        case .llmGenerationCompleted: rank += 30
        case .failed, .maxIterationsReached: rank += 20
        case .completed: rank += 5
        case .idle: rank += 0
        }
        if currentRunID != nil { rank += 20 }
        return rank
    }

    /// `true` when `self` looks like a stale mid-turn snapshot compared to `other` (same run, lower activity).
    public func isRegressiveOrchestrationWireSnapshot(comparedTo other: ConversationOrchestrationState) -> Bool {
        if other.currentRunID != nil, currentRunID == nil, !indicatesActiveOrchestrationTurn {
            return false
        }
        guard let otherRunID = other.currentRunID, currentRunID == otherRunID else {
            return false
        }
        return wireOrchestrationActivityRank < other.wireOrchestrationActivityRank
    }

    /// Whether this snapshot represents an in-flight user send / agent loop (not fully settled idle).
    public var indicatesActiveOrchestrationTurn: Bool {
        if currentRunID != nil { return true }
        switch agenticPhase {
        case .idle, .completed:
            break
        default:
            return true
        }
        switch llmRequestPhase {
        case .queued, .active, .generating, .streaming:
            return true
        case .idle, .completed, .failed, .cancelled, .none:
            break
        }
        switch llmRuntimePhase {
        case .generatingReasoning, .generatingResponding:
            return true
        case .idleReady, .idleCompleted, .failed:
            break
        }
        return false
    }

    /// Whether `incoming` should replace `current` for UI when both may arrive out of order (e.g. WebSocket).
    ///
    /// - If either payload omits ``orchestrationGeneration``, the update is applied unless it regresses a newer in-flight snapshot.
    /// - If both carry a generation, the update applies when `incoming >= current` and does not regress at the same generation.
    public static func shouldApplyOrchestrationUpdate(
        incoming: ConversationOrchestrationState,
        replacing current: ConversationOrchestrationState?
    ) -> Bool {
        guard let current else { return true }
        if incoming.isRegressiveOrchestrationWireSnapshot(comparedTo: current) {
            return false
        }
        switch (incoming.orchestrationGeneration, current.orchestrationGeneration) {
        case (nil, _), (_, nil):
            return true
        case let (inc?, cur?):
            return inc >= cur
        }
    }

    /// Interprets JSON values for ``orchestrationGeneration`` (Int/UInt64/Double/NSNumber from `JSONSerialization`).
    public static func orchestrationGeneration(fromJSONValue value: Any?) -> UInt64? {
        guard let value else { return nil }
        if let u = value as? UInt64 { return u }
        if let i = value as? Int, i >= 0 { return UInt64(i) }
        if let d = value as? Double, d >= 0, d <= Double(UInt64.max) { return UInt64(d) }
        if let n = value as? NSNumber { return n.uint64Value }
        return nil
    }
}

/// Streams returned from sending a chat message (partial streaming fragments + optional turn state observation).
public struct ChatStreamResponse: Sendable {
    public let partialContent: AsyncStream<ChatStreamingPartial>
    public let orchestrationState: AsyncStream<ConversationOrchestrationState>
    /// Run identifier for this send / streaming orchestration (matches ``ConversationOrchestrationState/currentRunID`` when generating).
    public let runID: UUID?
    /// Harness-visible opening input message id when this stream originates from appendInput.
    public let messageID: UUID?
    /// Conversation this stream mutates (required for transport routing).
    public let conversationID: UUID
    @available(*, deprecated, renamed: "orchestrationState")
    public var turnState: AsyncStream<ConversationOrchestrationState> { orchestrationState }

    public init(
        partialContent: AsyncStream<ChatStreamingPartial>,
        orchestrationState: AsyncStream<ConversationOrchestrationState>,
        conversationID: UUID,
        runID: UUID? = nil,
        messageID: UUID? = nil
    ) {
        self.partialContent = partialContent
        self.orchestrationState = orchestrationState
        self.conversationID = conversationID
        self.runID = runID
        self.messageID = messageID
    }

}

@available(*, deprecated, renamed: "ConversationOrchestrationState")
public typealias ConversationTurnState = ConversationOrchestrationState
