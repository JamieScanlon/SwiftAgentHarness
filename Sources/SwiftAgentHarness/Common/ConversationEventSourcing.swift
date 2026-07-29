import Foundation
import SwiftAgentKit

// Turn-summary projection and shared event payloads (including context compaction checkpoints).

enum ConversationEventKind: String {
    case messageAppended = "message_appended"
    /// Raw-stream durability marker when interaction mode / phase changes (harness mode history).
    case interactionModeChanged = "interaction_mode_changed"
    /// Turn summary for UI projection (`SummaryCreatedEventPayload`).
    case turnSummaryEvent = "turn_summary_event"
    case turnFinalized = "turn_finalized"
    case compactionApplied = "compaction_applied"
    /// Durable checkpoint for `ContextCompactionTransformer` (independent from `turnSummaryEvent`).
    case contextCompactionCheckpoint = "context_compaction_checkpoint"
    case memoryInjectionSnapshotCheckpoint = "memory_injection_snapshot_checkpoint"
    case toolResultTrimCheckpoint = "tool_result_trim_checkpoint"
    case systemPromptAssemblyCheckpoint = "system_prompt_assembly_checkpoint"
    case attachmentProjectionCheckpoint = "attachment_projection_checkpoint"
    case attachmentDigestCheckpoint = "attachment_digest_checkpoint"
    /// Derived run lifecycle marker (`running` -> terminal) used for durable run history projection.
    case runLifecycleEvent = "run_lifecycle_event"
    /// Derived tool approval/elevated lifecycle audit, projected from runtime lifecycle topic events.
    case toolAuditLifecycleEvent = "tool_audit_lifecycle_event"
    /// Derived runtime tool usage summary projected from runtime lifecycle topic events.
    case toolUsageSummaryEvent = "tool_usage_summary_event"
    /// Derived marker for delegated completion announcement delivery state.
    case completionAnnounceEvent = "completion_announce_event"
    /// Invalidates prior checkpoints for selected harness kinds (`CheckpointInvalidatedEventPayload`).
    case checkpointInvalidated = "checkpoint_invalidated"
}

/// Stable strings for ``CheckpointInvalidatedEventPayload.kinds`` (archive hook + compaction floor + UI projection).
enum HarnessCheckpointInvalidationKind {
    /// Matches REST/checkpoint latest harness kind `context_compaction`.
    static let contextCompaction = "context_compaction"
    /// Supersedes persisted ``ConversationEventKind.turnSummaryEvent`` rows for UI projection.
    static let turnSummaryEvent = "turn_summary_event"
    static let memoryInjectionSnapshot = HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue
    static let toolResultTrim = HarnessCheckpointWireKind.toolResultTrim.rawValue
    static let systemPromptAssembly = HarnessCheckpointWireKind.systemPromptAssembly.rawValue
    static let attachmentProjection = HarnessCheckpointWireKind.attachmentProjection.rawValue
    static let attachmentDigest = HarnessCheckpointWireKind.attachmentDigest.rawValue
    /// Internal marker for cache-aware pruning strategy drifts / TTL expiry invalidation.
    static let cacheAwarePruning = "cache_aware_pruning"
}

/// Harness checkpoint kind string aligned with ``LatestCheckpointResponse/kind`` (`context_compaction`).
struct CheckpointInvalidatedEventPayload: Codable, Sendable {
    /// Empty means “all registered harness checkpoint kinds” for the conversation (caller-defined).
    let kinds: [String]
}

struct MessageAppendedEventPayload: Codable {
    let messageID: UUID
}

struct SummaryCreatedEventPayload: Codable {
    let summaryMessageID: UUID
    let summaryContent: String
    let coveredMessageIDs: [UUID]
    let firstCoveredMessageID: UUID?
    let basedOnEventID: Int
    let startEventID: Int
    let endEventID: Int
    /// Tail raw ``Message.id`` for the covered slice (harness anchor for branch inheritance).
    let basedOnTailMessageID: UUID?
    let succeeded: Bool
    let createdAt: Date

    init(
        summaryMessageID: UUID,
        summaryContent: String,
        coveredMessageIDs: [UUID],
        firstCoveredMessageID: UUID?,
        basedOnEventID: Int,
        startEventID: Int,
        endEventID: Int,
        basedOnTailMessageID: UUID? = nil,
        succeeded: Bool,
        createdAt: Date
    ) {
        self.summaryMessageID = summaryMessageID
        self.summaryContent = summaryContent
        self.coveredMessageIDs = coveredMessageIDs
        self.firstCoveredMessageID = firstCoveredMessageID
        self.basedOnEventID = basedOnEventID
        self.startEventID = startEventID
        self.endEventID = endEventID
        self.basedOnTailMessageID = basedOnTailMessageID ?? coveredMessageIDs.last
        self.succeeded = succeeded
        self.createdAt = createdAt
    }
}

struct TurnFinalizedEventPayload: Codable {
    let basedOnEventID: Int
    let createdAt: Date
}

struct RunLifecycleEventPayload: Codable, Sendable {
    let runID: UUID
    let status: ConversationRunWireStatus
    let terminalReason: ConversationRunTerminalReason?
    /// Optional durable marker (`run_cancelled`, `run_orphaned`) for lifecycle closure semantics.
    let markerKind: String?
    let createdAt: Date
}

struct ToolAuditLifecycleEventPayload: Codable, Sendable {
    let name: RuntimeLifecycleEventName
    let runID: UUID?
    let iteration: Int?
    let modelID: UUID?
    let toolName: String
    let delegateHandleID: String?
    let toolCallID: String?
    let completionAnnounceID: UUID?
    let usage: DelegateCompletionUsagePayload?
    let approvalState: RuntimeLifecycleApprovalState?
    let policyReason: String?
    let approvalSource: String?
    let approvalReason: String?
    let argumentDigest: String?
    let argumentByteCount: Int?
    let argumentRedaction: String?
    let resultDigest: String?
    let resultByteCount: Int?
    let resultRedaction: String?
    let resultTruncated: Bool?
    let executionEnvironmentKind: String?
    let executionEnvironmentAdapterID: String?
    let executionIsolationLevel: String?
    let source: String?
    let createdAt: Date
}

struct ToolUsageSummaryEventPayload: Codable, Sendable {
    let runID: UUID?
    let toolCount: Int
    let toolNames: [String]
    let summaryText: String?
    let source: String?
    let createdAt: Date
}

/// The announcement content a delivery attempt failed to append, narrowed to the fields an
/// announcement message actually carries. Persisted alongside the announce event so a retry that
/// resumes after a process restart has something to re-append, rather than only being able to
/// re-publish the lifecycle event and settle at `fallback`.
struct CompletionAnnounceNotificationPayload: Codable, Sendable {
    let messageID: UUID
    let role: String
    let content: String
    let timestamp: Date
    let toolCallID: String?
    let responseFormat: String?
    /// Carried rather than dropped: trust classification decides how the re-appended content is
    /// treated, so losing it would change the meaning of the recovered message.
    let inputTrustRaw: String?

    /// Fails when the message carries fields this payload cannot represent, so a lossy copy is
    /// never persisted in place of the real one. Such a payload stays in-memory only, which is the
    /// behaviour that applied to every payload before this type existed.
    init?(message: Message) {
        guard message.images.isEmpty, message.toolCalls.isEmpty else { return nil }
        self.messageID = message.id
        self.role = message.role.rawValue
        self.content = message.content
        self.timestamp = message.timestamp
        self.toolCallID = message.toolCallId
        self.responseFormat = message.responseFormat
        self.inputTrustRaw = message.inputTrustRaw
    }

    /// Nil when the persisted role no longer decodes, rather than silently substituting one — the
    /// role decides which side of the transcript the announcement lands on.
    var message: Message? {
        guard let messageRole = MessageRole(rawValue: role) else { return nil }
        return Message(
            id: messageID,
            role: messageRole,
            content: content,
            timestamp: timestamp,
            toolCallId: toolCallID,
            responseFormat: responseFormat,
            inputTrustRaw: inputTrustRaw
        )
    }
}

struct CompletionAnnounceEventPayload: Codable, Sendable {
    let announce: CompletionAnnouncePayload
    let runtimePublished: Bool
    let subagentPublished: Bool
    let retryCount: Int
    /// `pending`, `delivered`, or `fallback`.
    let deliveryState: String
    /// Retained only while the content is the unresolved half of a `pending` announcement. Rows
    /// written before this field existed decode as nil, which is the pre-existing behaviour.
    let pendingNotification: CompletionAnnounceNotificationPayload?
    let createdAt: Date

    init(
        announce: CompletionAnnouncePayload,
        runtimePublished: Bool,
        subagentPublished: Bool,
        retryCount: Int,
        deliveryState: String,
        pendingNotification: CompletionAnnounceNotificationPayload? = nil,
        createdAt: Date
    ) {
        self.announce = announce
        self.runtimePublished = runtimePublished
        self.subagentPublished = subagentPublished
        self.retryCount = retryCount
        self.deliveryState = deliveryState
        self.pendingNotification = pendingNotification
        self.createdAt = createdAt
    }
}

struct InteractionModeChangedEventPayload: Codable, Sendable, Equatable {
    public var fromMode: String
    public var toMode: String
    public var fromProfileID: String
    public var toProfileID: String
    public var fromPhase: String
    public var toPhase: String
    /// `api`, `websocket`, `internal`, etc.
    public var initiatedBy: String
    public var reason: String?

    public init(
        fromMode: String,
        toMode: String,
        fromProfileID: String,
        toProfileID: String,
        fromPhase: String,
        toPhase: String,
        initiatedBy: String,
        reason: String? = nil
    ) {
        self.fromMode = fromMode
        self.toMode = toMode
        self.fromProfileID = fromProfileID
        self.toProfileID = toProfileID
        self.fromPhase = fromPhase
        self.toPhase = toPhase
        self.initiatedBy = initiatedBy
        self.reason = reason
    }
}

struct CompactionAppliedEventPayload: Codable {
    let uptoEventID: Int
    let snapshotID: UUID
    let createdAt: Date
}

enum ConversationEventCodec {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

enum ConversationEventProjector {
    typealias ProjectionMetrics = ConversationProjection.ProjectionMetrics

    /// - Parameter frontierEventID: Log tail from the same load as `events` (e.g. `MAX(eventID)` for the conversation). Pass `nil` only when the batch is guaranteed complete, in which case the engine uses `max(events.map(\.eventID))`.
    static func projectMessagesWithMetrics(
        baseMessages: [Message],
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil
    ) -> (messages: [Message], metrics: ProjectionMetrics, frontierEventID: Int) {
        ConversationProjection.projectMessagesWithMetrics(baseMessages: baseMessages, events: events, frontierEventID: frontierEventID)
    }

    /// - Parameter frontierEventID: Log tail from the same load as `events`. Pass `nil` only when the batch is guaranteed complete.
    static func projectMessages(
        baseMessages: [Message],
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil
    ) -> [Message] {
        ConversationProjection.projectMessages(baseMessages: baseMessages, events: events, frontierEventID: frontierEventID)
    }
}
