import Foundation

/// Client → server WebSocket control messages for the communication-layer slice.
public enum CommClientMessage: String, Codable, Sendable {
    case subscribe
    case unsubscribe
    case ack
    /// Idempotent ingress (`dedupeKey` + optional TTL) backed by harness `dedupe.sqlite` when installed.
    case dedupeCheckAndSet = "dedupe_check_and_set"
}

/// Parsed `{ "kind": "subscribe", "topic": "...", "since": N, ... }` WebSocket text frames.
/// Inbound frames are pre-validated in ``APILayer`` via ``WebSocketCommClientControlValidator`` before decode.
public struct CommClientControlMessage: Codable, Sendable {
    public var kind: CommClientMessage
    public var topic: String?
    public var since: Int?
    /// Conversation `…/events` only: last processed message-stream seq (dual replay). Omitted → skip message replay for that subscribe.
    public var sinceMessageSeq: Int?
    /// Conversation `…/events` only: last processed checkpoint-stream seq. Omitted → skip checkpoint replay.
    public var sinceCheckpointSeq: Int?
    /// Conversation `…/events` only: opaque resume cursor (see ``ConversationEventsResumeToken``).
    public var resumeToken: String?
    /// Cumulative ack cursor (`kind == .ack`): client consumed through this seq inclusive.
    public var upTo: Int?
    /// Optional conversation scope for global registry topics (`tools/registry`, `skills/registry`, `sub-agents/registry`).
    public var conversationId: String?
    /// Inbound idempotency key (`kind == .dedupeCheckAndSet`).
    public var dedupeKey: String?
    /// Optional TTL seconds for dedupe row (`kind == .dedupeCheckAndSet`); server clamps to configured bounds and applies a default when omitted.
    public var dedupeTtlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case kind, topic, since, sinceMessageSeq, sinceCheckpointSeq, resumeToken, upTo
        case dedupeKey, dedupeTtlSeconds, conversationId
    }

    public init(
        kind: CommClientMessage,
        topic: String?,
        since: Int? = nil,
        sinceMessageSeq: Int? = nil,
        sinceCheckpointSeq: Int? = nil,
        resumeToken: String? = nil,
        upTo: Int? = nil,
        dedupeKey: String? = nil,
        dedupeTtlSeconds: Int? = nil,
        conversationId: String? = nil
    ) {
        self.kind = kind
        self.topic = topic
        self.since = since
        self.sinceMessageSeq = sinceMessageSeq
        self.sinceCheckpointSeq = sinceCheckpointSeq
        self.resumeToken = resumeToken
        self.upTo = upTo
        self.dedupeKey = dedupeKey
        self.dedupeTtlSeconds = dedupeTtlSeconds
        self.conversationId = conversationId
    }
}

/// Standard values for harness ``CommResourceTopicMessage/hint`` on `lagging` envelopes.
public enum HarnessWireHints {
    public static let resync = "resync"
    public static let flowPressure = "flow_pressure"
}

/// Server → client envelope for `model/{id}/state` (and future resource topics).
public enum CommServerMessageKind: String, Codable, Sendable {
    case snapshot
    case event
    case lagging
}

/// Effective enforcement class for outbound harness envelopes.
public enum CommEnvelopeTrustClass: String, Codable, Sendable, Equatable {
    case trusted
    case restricted

    public init(policyClass: TrustPolicyClass) {
        switch policyClass {
        case .trusted:
            self = .trusted
        case .lowTrust:
            self = .restricted
        }
    }
}

/// Provenance class for outbound harness envelopes.
public enum CommEnvelopeOriginTrust: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    case userDirect = "user-direct"
    case userDeferred = "user-deferred"
    case knownParty = "known-party"
    case unknownParty = "unknown-party"
}

/// Canonical trust tag attached to each outbound ``CommResourceTopicMessage``.
public struct CommEnvelopeTrustTag: Codable, Sendable, Equatable {
    public var trustClass: CommEnvelopeTrustClass
    public var originTrust: CommEnvelopeOriginTrust

    public init(trustClass: CommEnvelopeTrustClass, originTrust: CommEnvelopeOriginTrust) {
        self.trustClass = trustClass
        self.originTrust = originTrust
    }

    public static let systemTrusted = CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .system)
    public static let unknownRestricted = CommEnvelopeTrustTag(trustClass: .restricted, originTrust: .unknownParty)

    public static func fromMessageInputTrustRaw(_ raw: String?) -> CommEnvelopeTrustTag {
        switch MessageInputTrustCodec.sanitizedInputTrustRaw(raw) {
        case MessageInputTrust.directUserEntry.rawValue:
            return CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .userDirect)
        case MessageInputTrust.automation.rawValue, MessageInputTrust.scripted.rawValue:
            return CommEnvelopeTrustTag(trustClass: .restricted, originTrust: .userDeferred)
        case .none:
            return .unknownRestricted
        case .some:
            return .unknownRestricted
        }
    }

    public static func fromSubAgentTrustRaw(_ raw: String?) -> CommEnvelopeTrustTag {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case CommEnvelopeOriginTrust.system.rawValue:
            return CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .system)
        case CommEnvelopeOriginTrust.userDirect.rawValue:
            return CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .userDirect)
        case CommEnvelopeOriginTrust.knownParty.rawValue:
            return CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .knownParty)
        case CommEnvelopeOriginTrust.userDeferred.rawValue:
            return CommEnvelopeTrustTag(trustClass: .restricted, originTrust: .userDeferred)
        case CommEnvelopeOriginTrust.unknownParty.rawValue:
            return CommEnvelopeTrustTag(trustClass: .restricted, originTrust: .unknownParty)
        default:
            return .unknownRestricted
        }
    }

    /// Maps a recognized comm-envelope origin trust raw to execution policy class; returns `nil` for non-envelope vocab.
    public static func executionPolicyClass(forOriginTrustRaw raw: String?) -> TrustPolicyClass? {
        guard let sanitized = MessageInputTrustCodec.sanitizedInputTrustRaw(raw) else { return nil }
        let normalized = sanitized.lowercased()
        let recognized = CommEnvelopeOriginTrust.allCases.contains { $0.rawValue == normalized }
        guard recognized else { return nil }
        switch fromSubAgentTrustRaw(sanitized).trustClass {
        case .trusted:
            return .trusted
        case .restricted:
            return .lowTrust
        }
    }

    public static func mostRestrictive(
        _ tags: [CommEnvelopeTrustTag],
        fallback: CommEnvelopeTrustTag = .systemTrusted
    ) -> CommEnvelopeTrustTag {
        guard !tags.isEmpty else { return fallback }
        let trustClass: CommEnvelopeTrustClass = tags.contains(where: { $0.trustClass == .restricted }) ? .restricted : .trusted
        let originTrust = tags.max(by: { $0.originRiskRank < $1.originRiskRank })?.originTrust ?? fallback.originTrust
        return CommEnvelopeTrustTag(trustClass: trustClass, originTrust: originTrust)
    }

    private var originRiskRank: Int {
        switch originTrust {
        case .system:
            return 0
        case .userDirect:
            return 1
        case .knownParty:
            return 2
        case .userDeferred:
            return 3
        case .unknownParty:
            return 4
        }
    }
}

/// Payload for topic `model/{id}/state`.
public struct ModelStatePayload: Codable, Sendable, Equatable {
    public enum SchedulabilityStatus: String, Codable, Sendable, Equatable {
        case accepting
        case saturated
        case draining
        case offline
    }

    public var phase: ModelInvocationPhase
    /// Pool-derived “thinking” indicator for UI (connecting >200ms or reasoning-only streaming).
    public var thinking: Bool
    public var callId: UUID?
    public var updatedAt: Date

    /// Reserved for later spec fields (`inFlight`, rate-limit windows, etc.).
    public var inFlightCount: Int?

    /// Wall-clock timestamp of the most recent terminal phase (`done` / `errored` / `cancelled`)
    /// observed by the coordinator for this model. `nil` until the first call completes.
    /// Additive on V1: existing decoders ignore the missing key.
    public var lastCompletedAt: Date?
    /// Rolling recent latency estimate for this model (milliseconds, p50).
    public var recentLatencyMsP50: Double?
    /// Rolling recent latency estimate for this model (milliseconds, p95).
    public var recentLatencyMsP95: Double?
    /// Rolling throughput estimate for this model (tokens/second, p50).
    public var recentTokensPerSecond: Double?
    /// Recent rate-limit window hint, when known.
    public var rateLimitWindow: ModelRateLimitWindow?
    /// Lightweight model routing signal: should new work route to this model right now?
    public var accepting: Bool?
    /// Derived schedulability status for routing consumers.
    public var status: SchedulabilityStatus?
    /// Current concurrent active calls observed by the coordinator.
    public var concurrencyActive: Int?
    /// Configured model concurrency limit when known.
    public var concurrencyLimit: Int?
    /// Rolling pool error rate (1m window) used by routing heuristics.
    public var errorRate1m: Double?

    public init(
        phase: ModelInvocationPhase,
        thinking: Bool,
        callId: UUID? = nil,
        updatedAt: Date = Date(),
        inFlightCount: Int? = nil,
        lastCompletedAt: Date? = nil,
        recentLatencyMsP50: Double? = nil,
        recentLatencyMsP95: Double? = nil,
        recentTokensPerSecond: Double? = nil,
        rateLimitWindow: ModelRateLimitWindow? = nil,
        accepting: Bool? = nil,
        status: SchedulabilityStatus? = nil,
        concurrencyActive: Int? = nil,
        concurrencyLimit: Int? = nil,
        errorRate1m: Double? = nil
    ) {
        self.phase = phase
        self.thinking = thinking
        self.callId = callId
        self.updatedAt = updatedAt
        self.inFlightCount = inFlightCount
        self.lastCompletedAt = lastCompletedAt
        self.recentLatencyMsP50 = recentLatencyMsP50
        self.recentLatencyMsP95 = recentLatencyMsP95
        self.recentTokensPerSecond = recentTokensPerSecond
        self.rateLimitWindow = rateLimitWindow
        self.accepting = accepting
        self.status = status
        self.concurrencyActive = concurrencyActive
        self.concurrencyLimit = concurrencyLimit
        self.errorRate1m = errorRate1m
    }
}

public struct ModelCallRecord: Codable, Sendable, Equatable {
    public struct AttemptRecord: Codable, Sendable, Equatable {
        public var attemptIndex: Int
        public var kind: ModelCallAttemptKind
        public var outcome: ModelCallAttemptOutcome
        public var observedAt: Date
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
        public var errorClass: String?
        public var errorCode: String?
        public var latencyMs: Double?

        public init(
            attemptIndex: Int,
            kind: ModelCallAttemptKind,
            outcome: ModelCallAttemptOutcome,
            observedAt: Date = Date(),
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
            errorClass: String? = nil,
            errorCode: String? = nil,
            latencyMs: Double? = nil
        ) {
            self.attemptIndex = attemptIndex
            self.kind = kind
            self.outcome = outcome
            self.observedAt = observedAt
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
            self.errorClass = errorClass
            self.errorCode = errorCode
            self.latencyMs = latencyMs
        }
    }

    public var callID: UUID
    public var logicalRequestID: UUID?
    public var rootCallID: UUID?
    public var attemptIndex: Int?
    public var conversationID: UUID?
    public var phase: ModelInvocationPhase
    public var startedAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var attempts: [AttemptRecord]

    public init(
        callID: UUID,
        logicalRequestID: UUID? = nil,
        rootCallID: UUID? = nil,
        attemptIndex: Int? = nil,
        conversationID: UUID?,
        phase: ModelInvocationPhase,
        startedAt: Date,
        updatedAt: Date,
        endedAt: Date? = nil,
        attempts: [AttemptRecord] = []
    ) {
        self.callID = callID
        self.logicalRequestID = logicalRequestID
        self.rootCallID = rootCallID
        self.attemptIndex = attemptIndex
        self.conversationID = conversationID
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.attempts = attempts
    }
}

/// Payload for topic `model/{id}/calls`.
public struct ModelCallsPayload: Codable, Sendable, Equatable {
    public var modelID: UUID
    public var active: [ModelCallRecord]
    public var recent: [ModelCallRecord]
    public var updatedAt: Date

    public init(
        modelID: UUID,
        active: [ModelCallRecord],
        recent: [ModelCallRecord] = [],
        updatedAt: Date = Date()
    ) {
        self.modelID = modelID
        self.active = active
        self.recent = recent
        self.updatedAt = updatedAt
    }
}

public struct ModelRateLimitWindow: Codable, Sendable, Equatable {
    public var active: Bool
    public var lastObservedAt: Date?
    public var retryAfterSeconds: Double?

    public init(active: Bool, lastObservedAt: Date? = nil, retryAfterSeconds: Double? = nil) {
        self.active = active
        self.lastObservedAt = lastObservedAt
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Per-priority breakdown of waiters currently parked in the scheduler queue. Sums to the
/// containing ``PoolHealthPayload/queueDepth``.
public struct PoolHealthQueueDepth: Codable, Sendable, Equatable {
    public var foreground: Int
    public var background: Int

    public init(foreground: Int, background: Int) {
        self.foreground = foreground
        self.background = background
    }
}

/// Payload for topic `pool/health` (aggregate pool / scheduler backpressure).
public struct PoolHealthPayload: Codable, Sendable, Equatable {
    public var queueDepth: Int
    public var inFlight: Int
    public var maxConcurrent: Int
    public var updatedAt: Date
    /// Placeholder for future observability; omitted in JSON when nil.
    public var errorRate: Double?
    /// Placeholder for future budget tracking; omitted in JSON when nil. Populated at the
    /// composition root from ``BudgetReporting/poolBudgetRemainingUSD()`` (default ``NilBudgetReporting``
    /// returns nil so the field stays absent until real accounting lands).
    public var budgetRemaining: Double?
    /// Per-priority queue depth breakdown. Sums to ``queueDepth``. Additive on V1: existing
    /// decoders ignore the missing key.
    public var queueDepthByPriority: PoolHealthQueueDepth?
    /// Rolling pool latency estimate in milliseconds (p50 across recent completed calls).
    public var rollingLatencyMsP50: Double?
    /// Rolling pool latency estimate in milliseconds (p95 across recent completed calls).
    public var rollingLatencyMsP95: Double?
    /// Count of prompt-cache plans evaluated by the pool wrappers.
    public var promptCachePlanningCount: Int?

    public init(
        queueDepth: Int,
        inFlight: Int,
        maxConcurrent: Int,
        updatedAt: Date = Date(),
        errorRate: Double? = nil,
        budgetRemaining: Double? = nil,
        queueDepthByPriority: PoolHealthQueueDepth? = nil,
        rollingLatencyMsP50: Double? = nil,
        rollingLatencyMsP95: Double? = nil,
        promptCachePlanningCount: Int? = nil
    ) {
        self.queueDepth = queueDepth
        self.inFlight = inFlight
        self.maxConcurrent = maxConcurrent
        self.updatedAt = updatedAt
        self.errorRate = errorRate
        self.budgetRemaining = budgetRemaining
        self.queueDepthByPriority = queueDepthByPriority
        self.rollingLatencyMsP50 = rollingLatencyMsP50
        self.rollingLatencyMsP95 = rollingLatencyMsP95
        self.promptCachePlanningCount = promptCachePlanningCount
    }
}

/// Payload for topic `models/registry` (full snapshot; delivered on subscribe and cached
/// in ``ModelStateTopicHub`` so late subscribers replay the latest state).
public struct ModelsRegistryPayload: Codable, Sendable {
    public var models: [Model]
    public var updatedAt: Date

    public init(models: [Model], updatedAt: Date = Date()) {
        self.models = models
        self.updatedAt = updatedAt
    }
}

/// Discriminator for ``ModelRegistryChange``. Wire format is the lowercase enum name.
public enum ModelRegistryChangeKind: String, Codable, Sendable, Equatable {
    case added
    case removed
    case updated
}

/// One per-model delta in a ``ModelsRegistryEventPayload``. ``previous`` is populated for
/// `removed` and `updated` events, ``current`` for `added` and `updated`.
///
/// Not `Equatable` because ``Model`` does not synthesize `Equatable` (its upstream
/// `LLMCapability` / `ModelRequestFeatures` are reference-shaped). Tests compare via field-by-field
/// inspection or via JSON round-trip.
public struct ModelRegistryChange: Codable, Sendable {
    public var kind: ModelRegistryChangeKind
    public var modelID: UUID
    public var previous: Model?
    public var current: Model?

    public init(kind: ModelRegistryChangeKind, modelID: UUID, previous: Model? = nil, current: Model? = nil) {
        self.kind = kind
        self.modelID = modelID
        self.previous = previous
        self.current = current
    }
}

/// Granular event payload for topic `models/registry`. Sent as `kind == .event` whenever
/// the registry changes; `kind == .snapshot` continues to ship ``ModelsRegistryPayload``
/// on subscribe (and on lagging recovery).
public struct ModelsRegistryEventPayload: Codable, Sendable {
    public var changes: [ModelRegistryChange]
    public var updatedAt: Date

    public init(changes: [ModelRegistryChange], updatedAt: Date = Date()) {
        self.changes = changes
        self.updatedAt = updatedAt
    }
}

/// Typed server → client message for resource topics (per-topic `seq` and `value`).
public struct CommResourceTopicMessage<Payload: Codable & Sendable>: Codable, Sendable {
    public var kind: CommServerMessageKind
    public var topic: String
    public var trustClass: CommEnvelopeTrustClass
    public var originTrust: CommEnvelopeOriginTrust
    /// Top-level envelope sequence for the subscribed topic stream.
    public var seq: Int?
    public var value: Payload?
    public var hint: String?
    /// Present on `conversation/{id}/events` `event` envelopes: monotonic seq for persisted message-shaped stream replay.
    public var messageSeq: Int?
    /// Present on `conversation/{id}/events` `event` envelopes: monotonic seq for checkpoint stream replay.
    public var checkpointSeq: Int?
    /// Transient `conversation/{id}/events` only: turn-scoped run id (minted at `turn.started`).
    public var runId: UUID?
    /// Transient `conversation/{id}/events` only: monotonic ordinal within ``runId``.
    public var turnOrdinal: Int?
    /// Optional server-minted resume cursor on conversation events subscribe handshake.
    public var resumeToken: String?

    enum CodingKeys: String, CodingKey {
        case kind, topic, trustClass, originTrust, seq, value, hint, messageSeq, checkpointSeq, runId, turnOrdinal, resumeToken
    }

    public init(
        snapshot topic: String,
        seq: Int,
        value: Payload,
        messageSeq: Int? = nil,
        checkpointSeq: Int? = nil,
        resumeToken: String? = nil,
        trustTag: CommEnvelopeTrustTag = .systemTrusted
    ) {
        self.kind = .snapshot
        self.topic = topic
        self.trustClass = trustTag.trustClass
        self.originTrust = trustTag.originTrust
        self.seq = seq
        self.value = value
        self.hint = nil
        self.messageSeq = messageSeq
        self.checkpointSeq = checkpointSeq
        self.runId = nil
        self.turnOrdinal = nil
        self.resumeToken = resumeToken
    }

    public init(
        event topic: String,
        seq: Int,
        value: Payload,
        messageSeq: Int? = nil,
        checkpointSeq: Int? = nil,
        trustTag: CommEnvelopeTrustTag = .systemTrusted
    ) {
        self.kind = .event
        self.topic = topic
        self.trustClass = trustTag.trustClass
        self.originTrust = trustTag.originTrust
        self.seq = seq
        self.value = value
        self.hint = nil
        self.messageSeq = messageSeq
        self.checkpointSeq = checkpointSeq
        self.runId = nil
        self.turnOrdinal = nil
        self.resumeToken = nil
    }

    /// Transient harness event: carries envelope ``seq`` plus ``runId`` / ``turnOrdinal`` ordering metadata.
    public init(
        transientEvent topic: String,
        seq: Int,
        value: Payload,
        runId: UUID,
        turnOrdinal: Int,
        trustTag: CommEnvelopeTrustTag = .systemTrusted
    ) {
        self.kind = .event
        self.topic = topic
        self.trustClass = trustTag.trustClass
        self.originTrust = trustTag.originTrust
        self.seq = seq
        self.value = value
        self.hint = nil
        self.messageSeq = nil
        self.checkpointSeq = nil
        self.runId = runId
        self.turnOrdinal = turnOrdinal
        self.resumeToken = nil
    }

    public init(
        lagging topic: String,
        seq: Int,
        hint: String,
        resumeToken: String? = nil,
        trustTag: CommEnvelopeTrustTag = .systemTrusted
    ) {
        self.kind = .lagging
        self.topic = topic
        self.trustClass = trustTag.trustClass
        self.originTrust = trustTag.originTrust
        self.seq = seq
        self.value = nil
        self.hint = hint
        self.messageSeq = nil
        self.checkpointSeq = nil
        self.runId = nil
        self.turnOrdinal = nil
        self.resumeToken = resumeToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(CommServerMessageKind.self, forKey: .kind)
        topic = try c.decode(String.self, forKey: .topic)
        trustClass = try c.decode(CommEnvelopeTrustClass.self, forKey: .trustClass)
        originTrust = try c.decode(CommEnvelopeOriginTrust.self, forKey: .originTrust)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        value = try c.decodeIfPresent(Payload.self, forKey: .value)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        messageSeq = try c.decodeIfPresent(Int.self, forKey: .messageSeq)
        checkpointSeq = try c.decodeIfPresent(Int.self, forKey: .checkpointSeq)
        runId = try c.decodeIfPresent(UUID.self, forKey: .runId)
        turnOrdinal = try c.decodeIfPresent(Int.self, forKey: .turnOrdinal)
        resumeToken = try c.decodeIfPresent(String.self, forKey: .resumeToken)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(topic, forKey: .topic)
        try c.encode(trustClass, forKey: .trustClass)
        try c.encode(originTrust, forKey: .originTrust)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(hint, forKey: .hint)
        try c.encodeIfPresent(messageSeq, forKey: .messageSeq)
        try c.encodeIfPresent(checkpointSeq, forKey: .checkpointSeq)
        try c.encodeIfPresent(runId, forKey: .runId)
        try c.encodeIfPresent(turnOrdinal, forKey: .turnOrdinal)
        try c.encodeIfPresent(resumeToken, forKey: .resumeToken)
    }
}

/// Envelope for `model/{id}/state` (type alias for call sites).
public typealias ModelStateResourceMessage = CommResourceTopicMessage<ModelStatePayload>

public enum ResourceTopicName {
    public static let poolHealth = "pool/health"
    public static let modelsRegistry = "models/registry"
    /// Account/session catalog change feed for conversation list mutations.
    public static let conversationsRegistry = "conversations/registry"
    /// Session-scoped tool listing for the server’s current conversation.
    public static let toolsRegistry = "tools/registry"
    public static let skillsRegistry = "skills/registry"
    /// v1: A2A delegate tools only (same rows as ``AvailableToolInfo`` with ``ToolListingSource/a2a``).
    public static let subAgentsRegistry = "sub-agents/registry"
    public static let traceServer = "trace/server"

    public static func subAgentLifecycleEvents(conversationID: UUID, path: [String]) -> String {
        "subagent/\(conversationID.uuidString.lowercased())/\(path.joined(separator: "/"))/events"
    }

    public static func subAgentLifecycleState(conversationID: UUID, path: [String]) -> String {
        "subagent/\(conversationID.uuidString.lowercased())/\(path.joined(separator: "/"))/state"
    }

    public static func traceConversation(conversationID: UUID) -> String {
        "trace/\(conversationID.uuidString.lowercased())"
    }
}

public enum SubAgentTopicFormat {
    public enum Kind: String, Sendable {
        case events
        case state
    }

    public struct ParsedTopic: Sendable, Equatable {
        public var conversationID: UUID
        public var pathSegments: [String]
        public var kind: Kind

        public init(conversationID: UUID, pathSegments: [String], kind: Kind) {
            self.conversationID = conversationID
            self.pathSegments = pathSegments
            self.kind = kind
        }
    }

    public static func eventsTopic(conversationID: UUID, pathSegments: [String]) -> String {
        ResourceTopicName.subAgentLifecycleEvents(conversationID: conversationID, path: pathSegments)
    }

    public static func stateTopic(conversationID: UUID, pathSegments: [String]) -> String {
        ResourceTopicName.subAgentLifecycleState(conversationID: conversationID, path: pathSegments)
    }

    public static func parse(_ topic: String) -> ParsedTopic? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "subagent", let conversationID = UUID(uuidString: parts[1]) else {
            return nil
        }
        guard let kind = Kind(rawValue: parts[parts.count - 1]) else {
            return nil
        }
        let pathSegments = Array(parts[2..<(parts.count - 1)])
        guard !pathSegments.isEmpty else { return nil }
        guard pathSegments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return ParsedTopic(conversationID: conversationID, pathSegments: pathSegments, kind: kind)
    }

    public static func parseEventsTopic(_ topic: String) -> ParsedTopic? {
        guard let parsed = parse(topic), parsed.kind == .events else { return nil }
        return parsed
    }

    public static func parseStateTopic(_ topic: String) -> ParsedTopic? {
        guard let parsed = parse(topic), parsed.kind == .state else { return nil }
        return parsed
    }
}

public enum TraceTopicFormat {
    public static let serverTopic = ResourceTopicName.traceServer

    public static func conversationTopic(conversationID: UUID) -> String {
        ResourceTopicName.traceConversation(conversationID: conversationID)
    }

    public static func parseConversationTopic(_ topic: String) -> UUID? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count == 2,
              parts[0] == "trace",
              parts[1] != "server",
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return id
    }

    public static func isServerTopic(_ topic: String) -> Bool {
        topic == serverTopic
    }
}

public struct TraceSpanPayload: Codable, Sendable, Equatable {
    public var spanID: UUID
    public var traceID: UUID
    public var name: String
    public var category: String
    public var source: String
    public var conversationID: UUID?
    public var runID: UUID?
    public var timestamp: Date
    public var attributes: [String: String]?

    public init(
        spanID: UUID = UUID(),
        traceID: UUID,
        name: String,
        category: String,
        source: String,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        timestamp: Date = Date(),
        attributes: [String: String]? = nil
    ) {
        self.spanID = spanID
        self.traceID = traceID
        self.name = name
        self.category = category
        self.source = source
        self.conversationID = conversationID
        self.runID = runID
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

public struct TraceTopicPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var spans: [TraceSpanPayload]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        spans: [TraceSpanPayload],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.spans = spans
        self.updatedAt = updatedAt
    }
}

public struct ConversationTraceResponse: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var spans: [TraceSpanPayload]
    public var updatedAt: Date

    public init(conversationID: UUID, spans: [TraceSpanPayload], updatedAt: Date = Date()) {
        self.conversationID = conversationID
        self.spans = spans
        self.updatedAt = updatedAt
    }
}

public enum SubAgentLifecyclePhase: String, Codable, Sendable, Equatable {
    case queued
    case dispatching
    case running
    case awaitingApproval = "awaiting-approval"
    case completing
    case done
    case failed
    case orphaned
}

public enum CompletionAnnounceStatus: String, Codable, Sendable, Equatable {
    case done
    case failed
}

public struct DelegateCompletionUsagePayload: Codable, Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Push-style completion announce envelope used across runtime lifecycle events and sub-agent lifecycle snapshots.
public struct CompletionAnnouncePayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var announceID: UUID
    public var delegateHandleID: String
    public var toolCallID: String
    public var conversationID: UUID
    public var parentConversationID: UUID?
    public var lifecycleID: String
    public var status: CompletionAnnounceStatus
    public var completedAt: Date
    public var source: String
    public var usage: DelegateCompletionUsagePayload?
    public var error: String?

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        announceID: UUID = UUID(),
        delegateHandleID: String,
        toolCallID: String,
        conversationID: UUID,
        parentConversationID: UUID? = nil,
        lifecycleID: String,
        status: CompletionAnnounceStatus,
        completedAt: Date,
        source: String,
        usage: DelegateCompletionUsagePayload? = nil,
        error: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.announceID = announceID
        self.delegateHandleID = delegateHandleID
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.parentConversationID = parentConversationID
        self.lifecycleID = lifecycleID
        self.status = status
        self.completedAt = completedAt
        self.source = source
        self.usage = usage
        self.error = error
    }
}

/// REST body for `POST …/completion-announcements` (OpenAPI `CompletionAnnounceTriggerRequest`).
public struct CompletionAnnounceTriggerRequest: Codable, Sendable, Equatable {
    public var announceID: UUID?
    public var delegateHandleID: String
    public var toolCallID: String
    public var lifecycleID: String
    public var parentConversationID: UUID?
    public var status: CompletionAnnounceStatus
    public var completedAt: Date?
    public var source: String?
    public var usage: DelegateCompletionUsagePayload?
    public var error: String?
    public var toolMessageContent: String?
}

/// REST row for `GET …/sub-agents/active`.
public struct ActiveSubAgentInvocationInfo: Codable, Sendable, Equatable {
    public var lifecycleID: String
    public var parentConversationID: UUID
    public var childConversationID: UUID?
    public var delegateToolName: String?
    public var transportKind: String?
    public var asyncHandleID: String?
    public var phase: SubAgentLifecyclePhase
    public var startedAt: Date?
    public var updatedAt: Date
    public var error: String?
}

public enum ToolApprovalRoute: String, Codable, Sendable, Equatable {
    case user
    case parent
}

public struct SubAgentLifecycleEntryPayload: Codable, Sendable, Equatable {
    public var lifecycleID: String
    public var parentConversationID: UUID
    public var childConversationID: UUID?
    public var delegateToolName: String?
    public var asyncHandleID: String?
    public var phase: SubAgentLifecyclePhase
    public var eventTrustLevel: String?
    public var defaultTrustLevel: String?
    public var permissionPolicy: String?
    public var approvalRoute: ToolApprovalRoute?
    public var completionAnnounceID: UUID?
    public var toolCallID: String?
    public var completionSource: String?
    public var completionUsage: DelegateCompletionUsagePayload?
    public var error: String?
    public var updatedAt: Date

    public init(
        lifecycleID: String,
        parentConversationID: UUID,
        childConversationID: UUID? = nil,
        delegateToolName: String? = nil,
        asyncHandleID: String? = nil,
        phase: SubAgentLifecyclePhase,
        eventTrustLevel: String? = nil,
        defaultTrustLevel: String? = nil,
        permissionPolicy: String? = nil,
        approvalRoute: ToolApprovalRoute? = nil,
        completionAnnounceID: UUID? = nil,
        toolCallID: String? = nil,
        completionSource: String? = nil,
        completionUsage: DelegateCompletionUsagePayload? = nil,
        error: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.lifecycleID = lifecycleID
        self.parentConversationID = parentConversationID
        self.childConversationID = childConversationID
        self.delegateToolName = delegateToolName
        self.asyncHandleID = asyncHandleID
        self.phase = phase
        self.eventTrustLevel = eventTrustLevel
        self.defaultTrustLevel = defaultTrustLevel
        self.permissionPolicy = permissionPolicy
        self.approvalRoute = approvalRoute
        self.completionAnnounceID = completionAnnounceID
        self.toolCallID = toolCallID
        self.completionSource = completionSource
        self.completionUsage = completionUsage
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct SubAgentLifecycleTopicPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var parentConversationID: UUID
    public var entries: [SubAgentLifecycleEntryPayload]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        parentConversationID: UUID,
        entries: [SubAgentLifecycleEntryPayload],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.parentConversationID = parentConversationID
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

// MARK: - Session capability registry topics (`tools/registry`, `skills/registry`, `sub-agents/registry`)

/// Payload for topic `tools/registry` (conversation-scoped snapshot/event stream for registry consumers).
public struct ToolsRegistryPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var conversationID: UUID?
    public var tools: [AvailableToolInfo]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        conversationID: UUID? = nil,
        tools: [AvailableToolInfo] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.conversationID = conversationID
        self.tools = tools
        self.updatedAt = updatedAt
    }
}

/// Payload for topic `skills/registry` (conversation-scoped snapshot/event stream for registry consumers).
public struct SkillsRegistryPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var conversationID: UUID?
    public var skills: [AvailableSkillInfo]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        conversationID: UUID? = nil,
        skills: [AvailableSkillInfo] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.conversationID = conversationID
        self.skills = skills
        self.updatedAt = updatedAt
    }
}

/// Wire row for topic `sub-agents/registry` schema v2.
public struct SubAgentRegistryEntryPayload: Codable, Sendable, Equatable {
    public var agentID: String
    public var displayName: String
    public var description: String
    public var delegateToolName: String
    public var source: ToolListingSource
    public var transportKind: String
    public var useClasses: [String]
    public var maxRecursionDepth: Int?
    public var streaming: Bool?
    public var longRunning: Bool?
    public var defaultTrustLevel: String
    public var permissionPolicy: String
    public var hostPersonaID: String?
    public var delegationAllowlist: [String]
    public var authScopeTags: [String]
    public var routingDomain: String?
    public var tenantScope: String?
    public var tool: AvailableToolInfo

    public init(
        agentID: String,
        displayName: String,
        description: String,
        delegateToolName: String,
        source: ToolListingSource,
        transportKind: String,
        useClasses: [String] = [],
        maxRecursionDepth: Int? = nil,
        streaming: Bool? = nil,
        longRunning: Bool? = nil,
        defaultTrustLevel: String = "unknown-party",
        permissionPolicy: String = "ask-user",
        hostPersonaID: String? = nil,
        delegationAllowlist: [String] = [],
        authScopeTags: [String] = [],
        routingDomain: String? = nil,
        tenantScope: String? = nil,
        tool: AvailableToolInfo
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.description = description
        self.delegateToolName = delegateToolName
        self.source = source
        self.transportKind = transportKind
        self.useClasses = useClasses
        self.maxRecursionDepth = maxRecursionDepth
        self.streaming = streaming
        self.longRunning = longRunning
        self.defaultTrustLevel = defaultTrustLevel
        self.permissionPolicy = permissionPolicy
        self.hostPersonaID = hostPersonaID
        self.delegationAllowlist = delegationAllowlist
        self.authScopeTags = authScopeTags
        self.routingDomain = routingDomain
        self.tenantScope = tenantScope
        self.tool = tool
    }
}

/// Payload for topic `sub-agents/registry`.
public struct SubAgentsRegistryPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1
    public static let schemaVersionV2 = 2

    public var schemaVersion: Int
    public var conversationID: UUID?
    /// Compatibility projection for existing clients that consume delegate tools by `source == a2a`.
    public var agents: [AvailableToolInfo]
    /// Canonical v2 registry rows.
    public var entries: [SubAgentRegistryEntryPayload]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV2,
        conversationID: UUID? = nil,
        agents: [AvailableToolInfo] = [],
        entries: [SubAgentRegistryEntryPayload] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.conversationID = conversationID
        self.agents = agents
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

/// Public projection for mode-picker/catalog transport (`GET /api/modes`).
public struct ModeProfileDTO: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var description: String?
    public var symbol: String?
    public var summary: ModeProfileSummary?

    public init(
        id: String,
        label: String,
        description: String? = nil,
        symbol: String? = nil,
        summary: ModeProfileSummary? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.symbol = symbol
        self.summary = summary
    }
}

/// REST wrapper body for mode profile catalog reads.
public struct ModesCatalogResponse: Codable, Sendable, Equatable {
    public var profiles: [ModeProfileDTO]

    public init(profiles: [ModeProfileDTO]) {
        self.profiles = profiles
    }
}

// MARK: - Account catalog topic (`conversations/registry`)

public struct ConversationRegistryChange: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case added
        case archived
        case deleted
        case updated
    }

    public var kind: Kind
    public var conversationID: UUID
    /// Optional summary row for clients that want incremental list updates.
    public var metadata: ConversationMetadata?

    public init(kind: Kind, conversationID: UUID, metadata: ConversationMetadata? = nil) {
        self.kind = kind
        self.conversationID = conversationID
        self.metadata = metadata
    }
}

/// Payload for topic `conversations/registry` (account/session conversation catalog deltas).
public struct ConversationsRegistryPayload: Codable, Sendable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    /// Optional account id until multi-tenant auth is wired.
    public var accountID: String?
    public var changes: [ConversationRegistryChange]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        accountID: String? = nil,
        changes: [ConversationRegistryChange] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.accountID = accountID
        self.changes = changes
        self.updatedAt = updatedAt
    }
}

public enum ModelStateTopicFormat {
    /// Topic string `model/{uuid}/state`
    public static func topic(modelID: UUID) -> String {
        "model/\(modelID.uuidString.lowercased())/state"
    }

    public static func parseModelStateTopic(_ topic: String) -> UUID? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count == 3,
              parts[0] == "model",
              parts[2] == "state",
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return id
    }
}

public enum ModelCallsTopicFormat {
    /// Topic string `model/{uuid}/calls`
    public static func topic(modelID: UUID) -> String {
        "model/\(modelID.uuidString.lowercased())/calls"
    }

    public static func parseModelCallsTopic(_ topic: String) -> UUID? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count == 3,
              parts[0] == "model",
              parts[2] == "calls",
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return id
    }
}

// MARK: - Conversation `conversation/{uuid}/events`

/// Harness-shaped topic for one ordered stream per conversation (see migration doc / harness communication-layer README).
public enum ConversationTopicFormat {
    /// Topic string `conversation/{uuid}/events`
    public static func topic(conversationID: UUID) -> String {
        "conversation/\(conversationID.uuidString.lowercased())/events"
    }

    /// Topic string `conversation/{uuid}/state`
    public static func stateTopic(conversationID: UUID) -> String {
        "conversation/\(conversationID.uuidString.lowercased())/state"
    }

    public static func parseConversationEventsTopic(_ topic: String) -> UUID? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count == 3,
              parts[0] == "conversation",
              parts[2] == "events",
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return id
    }

    public static func parseConversationStateTopic(_ topic: String) -> UUID? {
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count == 3,
              parts[0] == "conversation",
              parts[2] == "state",
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return id
    }
}

/// Token-budget snapshot for a conversation, derived from projection-policy context assembly
/// (with orchestration fallback when projection signals are unavailable). All fields optional
/// so partial data can flow even before a full turn has executed.
public struct ConversationContextBudget: Codable, Sendable, Equatable {
    public var contextLimitTokens: Int?
    public var promptTokens: Int?
    public var remainingTokens: Int?
    /// Optional cache-aware pruning metadata for clients that expose budget/caching diagnostics.
    public var cacheStablePrefixMessageCount: Int?
    public var cachePruningTTLSeconds: Double?
    public var compactionStrategy: String?

    public init(
        contextLimitTokens: Int? = nil,
        promptTokens: Int? = nil,
        remainingTokens: Int? = nil,
        cacheStablePrefixMessageCount: Int? = nil,
        cachePruningTTLSeconds: Double? = nil,
        compactionStrategy: String? = nil
    ) {
        self.contextLimitTokens = contextLimitTokens
        self.promptTokens = promptTokens
        self.remainingTokens = remainingTokens
        self.cacheStablePrefixMessageCount = cacheStablePrefixMessageCount
        self.cachePruningTTLSeconds = cachePruningTTLSeconds
        self.compactionStrategy = compactionStrategy
    }
}

/// Payload for topic `conversation/{id}/state` (coalesced metadata + orchestration + session flags).
public struct ConversationStatePayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1
    /// Adds persisted harness resource fields (lifecycle, lineage, tags, durable budget hints, branch index).
    public static let schemaVersionV2 = 2

    public var schemaVersion: Int
    public var conversationID: UUID
    /// `false` after delete or unknown id (snapshot still delivered so clients can resync).
    public var exists: Bool
    public var sessionSelected: Bool
    public var topic: String?
    public var interactionMode: InteractionMode?
    /// Persisted mode registry pointer used for runtime profile resolution.
    public var modeProfileID: String?
    public var modelID: UUID?
    public var modelName: String?
    public var messageCount: Int?
    public var updatedAt: Date?
    public var orchestration: ConversationOrchestrationState?
    /// Meaningful when ``sessionSelected``; always `false` when the conversation row is missing.
    public var replayActive: Bool
    /// Pool-derived per-call lifecycle for the conversation's currently selected ``modelID``. `nil` when
    /// the coordinator has not observed any call for that model (avoids forging a synthetic ``.done``
    /// snapshot for never-seen models). Additive on V1 — existing decoders ignore the missing key.
    public var poolModelState: ModelStatePayload?
    /// Currently dispatched model ID for this conversation (from the coordinator's reverse
    /// lookup over `activeConversationID`). `nil` when no in-flight call for the conversation.
    public var activeModelID: UUID?
    /// Currently dispatched call ID for this conversation. `nil` when no in-flight call.
    public var activeCallID: UUID?
    /// Token budget derived from projection policy (`contextBudgetRemaining` parity), with
    /// orchestration fallback when projection budget is unavailable.
    public var contextBudget: ConversationContextBudget?
    /// Projected USD spend for the conversation, sourced from ``BudgetReporting/projectedCostUSD(conversationID:)``.
    /// Default ``NilBudgetReporting`` returns nil so the field stays absent until real accounting lands.
    public var projectedCostUSD: Double?
    /// Persisted resource lifecycle (`schemaVersion` ≥ ``schemaVersionV2``).
    public var lifecycle: ConversationLifecycleState?
    /// Parent conversation in branch / sub-agent tree.
    public var parentConversationID: UUID?
    public var tags: [String]?
    /// Durable budget snapshot persisted on the conversation row (may overlap context orchestration hints).
    public var resourceBudgetSnapshot: ConversationBudgetSnapshot?
    /// Denormalized branch index (child id + branch-point message id on parent).
    public var branchChildren: [ConversationBranchRef]?
    /// Harness resource run status persisted for the conversation.
    public var resourceRunStatus: ConversationResourceRunStatus?
    /// Active run identifier when a turn is in flight (mirrors persisted ``ModelConversation/currentRunID``).
    public var currentRunID: UUID?
    /// Attached resources catalog (harness README: state publishes attachment changes). Omitted when empty.
    public var attachmentsCatalog: [ConversationAttachmentDescriptor]?

    public init(
        schemaVersion: Int = ConversationStatePayload.schemaVersionV2,
        conversationID: UUID,
        exists: Bool,
        sessionSelected: Bool,
        topic: String? = nil,
        interactionMode: InteractionMode? = nil,
        modeProfileID: String? = nil,
        modelID: UUID? = nil,
        modelName: String? = nil,
        messageCount: Int? = nil,
        updatedAt: Date? = nil,
        orchestration: ConversationOrchestrationState? = nil,
        replayActive: Bool = false,
        poolModelState: ModelStatePayload? = nil,
        activeModelID: UUID? = nil,
        activeCallID: UUID? = nil,
        contextBudget: ConversationContextBudget? = nil,
        projectedCostUSD: Double? = nil,
        lifecycle: ConversationLifecycleState? = nil,
        parentConversationID: UUID? = nil,
        tags: [String]? = nil,
        resourceBudgetSnapshot: ConversationBudgetSnapshot? = nil,
        branchChildren: [ConversationBranchRef]? = nil,
        resourceRunStatus: ConversationResourceRunStatus? = nil,
        currentRunID: UUID? = nil,
        attachmentsCatalog: [ConversationAttachmentDescriptor]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.conversationID = conversationID
        self.exists = exists
        self.sessionSelected = sessionSelected
        self.topic = topic
        self.interactionMode = interactionMode
        self.modeProfileID = modeProfileID
        self.modelID = modelID
        self.modelName = modelName
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.orchestration = orchestration
        self.replayActive = replayActive
        self.poolModelState = poolModelState
        self.activeModelID = activeModelID
        self.activeCallID = activeCallID
        self.contextBudget = contextBudget
        self.projectedCostUSD = projectedCostUSD
        self.lifecycle = lifecycle
        self.parentConversationID = parentConversationID
        self.tags = tags
        self.resourceBudgetSnapshot = resourceBudgetSnapshot
        self.branchChildren = branchChildren
        self.resourceRunStatus = resourceRunStatus
        self.currentRunID = currentRunID
        self.attachmentsCatalog = attachmentsCatalog
    }

    /// After ``ConversationStateTopicHub`` broadcasts a tombstone for a deleted conversation.
    public static func deleted(conversationID: UUID) -> ConversationStatePayload {
        ConversationStatePayload(
            schemaVersion: schemaVersionV2,
            conversationID: conversationID,
            exists: false,
            sessionSelected: false,
            orchestration: nil,
            replayActive: false,
            poolModelState: nil,
            activeModelID: nil,
            activeCallID: nil,
            contextBudget: nil,
            projectedCostUSD: nil,
            lifecycle: nil,
            parentConversationID: nil,
            tags: nil,
            resourceBudgetSnapshot: nil,
            branchChildren: nil,
            resourceRunStatus: nil,
            currentRunID: nil,
            attachmentsCatalog: nil
        )
    }
}

/// v1 payload for ``ConversationTopicFormat`` topic messages.
public struct ConversationTopicEventPayload: Codable, Sendable {
    public enum SemanticKind: String, Codable, Sendable {
        case messagesRefresh
        /// Harness-shaped ``ModelContentDeltaWire`` JSON in ``jsonUTF8``.
        case contentDelta
        case streamDone
        /// Pool-derived per-call lifecycle (`ModelStatePayload` JSON in ``jsonUTF8``).
        case modelLifecycle
        /// Runtime lifecycle taxonomy (`RuntimeLifecycleEventPayload` JSON in ``jsonUTF8``).
        case runtimeLifecycle
        /// Harness checkpoint notification (`ConversationCheckpointTopicEventWire` JSON in ``jsonUTF8``).
        case checkpoint
        /// Client surface intent (`ClientSurfaceIntent` JSON in ``jsonUTF8``).
        case surfaceIntent
    }

    public var semanticKind: SemanticKind
    /// JSON text: message rows (`messagesRefresh`),
    /// ``ModelContentDeltaWire`` (`contentDelta`), or ``ModelStatePayload`` (`modelLifecycle`).
    public var jsonUTF8: String?

    public init(semanticKind: SemanticKind, jsonUTF8: String? = nil) {
        self.semanticKind = semanticKind
        self.jsonUTF8 = jsonUTF8
    }

    /// `messagesRefresh` body: JSON array of message rows (same encoding as ``Message`` `.toJSON` at the wire edge).
    public static func messagesRefreshJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .messagesRefresh, jsonUTF8: utf8)
    }

    /// UTF-8 JSON encoding of ``ModelContentDeltaWire`` (`semanticKind == .contentDelta`).
    public static func contentDeltaJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .contentDelta, jsonUTF8: utf8)
    }

    public static let streamDone = ConversationTopicEventPayload(semanticKind: .streamDone)

    /// UTF-8 JSON encoding of ``ModelStatePayload`` for a per-call lifecycle transition derived from the
    /// Model Pool coordinator. Subscribers can use this to render pool-derived `thinking`/phase indicators
    /// without re-subscribing to `model/{id}/state`.
    public static func modelLifecycleJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .modelLifecycle, jsonUTF8: utf8)
    }

    /// UTF-8 JSON encoding of ``RuntimeLifecycleEventPayload`` (`semanticKind == .runtimeLifecycle`).
    public static func runtimeLifecycleJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .runtimeLifecycle, jsonUTF8: utf8)
    }

    /// UTF-8 JSON encoding of ``ConversationCheckpointTopicEventWire`` (`semanticKind == .checkpoint`).
    public static func checkpointJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .checkpoint, jsonUTF8: utf8)
    }

    /// UTF-8 JSON encoding of ``ClientSurfaceIntent`` (`semanticKind == .surfaceIntent`).
    public static func surfaceIntentJSONUTF8(_ utf8: String) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload(semanticKind: .surfaceIntent, jsonUTF8: utf8)
    }
}

public enum RuntimeLifecycleEventName: String, Codable, Sendable, Equatable {
    case turnStarted = "turn.started"
    case loopIterationStarted = "loop.iterationStarted"
    case modelCallStarted = "model.callStarted"
    case modelCallCompleted = "model.callCompleted"
    case toolCallStarted = "tool.callStarted"
    case toolCallCompleted = "tool.callCompleted"
    case toolCompletionAnnounced = "tool.completionAnnounced"
    case toolUsageSummary = "tool.usageSummary"
    case toolApprovalRequired = "tool.approvalRequired"
    case toolApprovalResolved = "tool.approvalResolved"
    case toolElevatedExecuted = "tool.elevatedExecuted"
    case loopIterationCompleted = "loop.iterationCompleted"
    case turnCompleted = "turn.completed"
    case turnCancelled = "turn.cancelled"
    case turnBounded = "turn.bounded"
    case subagentOrphaned = "subagent.orphaned"
}

public enum RuntimeLifecycleApprovalState: String, Codable, Sendable, Equatable {
    case approved
    case denied
    case pending
}

/// Runtime lifecycle event wire for `conversation/{id}/events` (`semanticKind == runtimeLifecycle`).
public struct RuntimeLifecycleEventPayload: Codable, Sendable, Equatable {
    public static let schemaVersionV1 = 1

    public var schemaVersion: Int
    public var name: RuntimeLifecycleEventName
    public var conversationID: UUID
    public var runID: UUID?
    public var iteration: Int?
    public var modelID: UUID?
    public var toolName: String?
    public var approvalState: RuntimeLifecycleApprovalState?
    public var policyReason: String?
    public var approvalSource: String?
    public var approvalReason: String?
    public var approvalRoute: ToolApprovalRoute?
    public var approvalTitle: String?
    public var approvalDescription: String?
    public var approvalSeverity: String?
    public var approvalTimeoutMs: Int?
    public var approvalTimeoutBehavior: String?
    public var approvalResolutionKind: String?
    public var approvalPresentation: ApprovalPresentation?
    public var originTrustLevel: String?
    public var parentConversationID: UUID?
    public var childConversationID: UUID?
    public var delegateHandleID: String?
    public var toolCallID: String?
    public var completionAnnounceID: UUID?
    public var usage: DelegateCompletionUsagePayload?
    public var argumentDigest: String?
    public var argumentByteCount: Int?
    public var argumentRedaction: String?
    public var resultDigest: String?
    public var resultByteCount: Int?
    public var resultRedaction: String?
    public var resultTruncated: Bool?
    public var executionEnvironmentKind: String?
    public var executionEnvironmentAdapterID: String?
    public var executionIsolationLevel: String?
    public var toolCount: Int?
    public var toolNames: [String]?
    public var summaryText: String?
    public var terminalReason: ConversationRunTerminalReason?
    public var source: String?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersionV1,
        name: RuntimeLifecycleEventName,
        conversationID: UUID,
        runID: UUID? = nil,
        iteration: Int? = nil,
        modelID: UUID? = nil,
        toolName: String? = nil,
        approvalState: RuntimeLifecycleApprovalState? = nil,
        policyReason: String? = nil,
        approvalSource: String? = nil,
        approvalReason: String? = nil,
        approvalRoute: ToolApprovalRoute? = nil,
        approvalTitle: String? = nil,
        approvalDescription: String? = nil,
        approvalSeverity: String? = nil,
        approvalTimeoutMs: Int? = nil,
        approvalTimeoutBehavior: String? = nil,
        approvalResolutionKind: String? = nil,
        approvalPresentation: ApprovalPresentation? = nil,
        originTrustLevel: String? = nil,
        parentConversationID: UUID? = nil,
        childConversationID: UUID? = nil,
        delegateHandleID: String? = nil,
        toolCallID: String? = nil,
        completionAnnounceID: UUID? = nil,
        usage: DelegateCompletionUsagePayload? = nil,
        argumentDigest: String? = nil,
        argumentByteCount: Int? = nil,
        argumentRedaction: String? = nil,
        resultDigest: String? = nil,
        resultByteCount: Int? = nil,
        resultRedaction: String? = nil,
        resultTruncated: Bool? = nil,
        executionEnvironmentKind: String? = nil,
        executionEnvironmentAdapterID: String? = nil,
        executionIsolationLevel: String? = nil,
        toolCount: Int? = nil,
        toolNames: [String]? = nil,
        summaryText: String? = nil,
        terminalReason: ConversationRunTerminalReason? = nil,
        source: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.conversationID = conversationID
        self.runID = runID
        self.iteration = iteration
        self.modelID = modelID
        self.toolName = toolName
        self.approvalState = approvalState
        self.policyReason = policyReason
        self.approvalSource = approvalSource
        self.approvalReason = approvalReason
        self.approvalRoute = approvalRoute
        self.approvalTitle = approvalTitle
        self.approvalDescription = approvalDescription
        self.approvalSeverity = approvalSeverity
        self.approvalTimeoutMs = approvalTimeoutMs
        self.approvalTimeoutBehavior = approvalTimeoutBehavior
        self.approvalResolutionKind = approvalResolutionKind
        self.approvalPresentation = approvalPresentation
        self.originTrustLevel = originTrustLevel
        self.parentConversationID = parentConversationID
        self.childConversationID = childConversationID
        self.delegateHandleID = delegateHandleID
        self.toolCallID = toolCallID
        self.completionAnnounceID = completionAnnounceID
        self.usage = usage
        self.argumentDigest = argumentDigest
        self.argumentByteCount = argumentByteCount
        self.argumentRedaction = argumentRedaction
        self.resultDigest = resultDigest
        self.resultByteCount = resultByteCount
        self.resultRedaction = resultRedaction
        self.resultTruncated = resultTruncated
        self.executionEnvironmentKind = executionEnvironmentKind
        self.executionEnvironmentAdapterID = executionEnvironmentAdapterID
        self.executionIsolationLevel = executionIsolationLevel
        self.toolCount = toolCount
        self.toolNames = toolNames
        self.summaryText = summaryText
        self.terminalReason = terminalReason
        self.source = source
        self.updatedAt = updatedAt
    }
}
