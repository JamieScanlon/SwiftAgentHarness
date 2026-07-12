import Foundation

/// Wire status for a conversation streaming run (append + orchestration).
public enum ConversationRunWireStatus: String, Codable, Sendable, Equatable {
    case running
    case completed
    case cancelled
    case failed
}

/// Terminal reason taxonomy for run lifecycle closure.
public enum ConversationRunTerminalCategory: String, Codable, Sendable, Equatable {
    case externalCancellation
    case naturalStop
    case boundedStop
    case failure
}

/// Optional bounded-stop subreason for runtime guardrail exits.
public enum ConversationRunBoundedReason: String, Codable, Sendable, Equatable {
    case maxAgentIterations
    case userStopRequested
    case runawayEmptyAssistantStreak
    case repeatToolCallStreak
    case chattyAssistantLimit
    case maxContinuationRounds
}

/// Optional terminal reason attached to durable run projections.
public struct ConversationRunTerminalReason: Codable, Sendable, Equatable {
    public let category: ConversationRunTerminalCategory
    public let boundedReason: ConversationRunBoundedReason?
    public let detail: String?

    public init(
        category: ConversationRunTerminalCategory,
        boundedReason: ConversationRunBoundedReason? = nil,
        detail: String? = nil
    ) {
        self.category = category
        self.boundedReason = boundedReason
        self.detail = detail
    }
}

/// Optional transcript-derived rollups for a single run (no token/cost fields until an authoritative ledger exists).
public struct ConversationRunToolRollup: Codable, Sendable, Equatable {
    /// Lexicographically sorted distinct tool names seen on assistant rows in this run.
    public let distinctToolNames: [String]
    /// Total tool-name slots across assistant rows (one row may list multiple tools).
    public let totalToolCallSlots: Int

    public init(distinctToolNames: [String], totalToolCallSlots: Int) {
        self.distinctToolNames = distinctToolNames
        self.totalToolCallSlots = totalToolCallSlots
    }
}

/// Authoritative token usage totals for a run.
/// Values are summed from persisted completion-usage rows linked to this `runID`.
public struct ConversationRunTokenRollup: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.totalTokens = max(0, totalTokens)
    }
}

/// Authoritative cost totals for a run.
/// `usd` is summed from persisted completion-usage rows linked to this `runID`.
public struct ConversationRunCostRollup: Codable, Sendable, Equatable {
    public let usd: Double

    public init(usd: Double) {
        self.usd = max(0, usd)
    }
}

/// Transcript-derived detail slice; absent on list responses unless expanded in the future.
public struct ConversationRunProjectionDetail: Codable, Sendable, Equatable {
    public let assistantMessageCount: Int
    public let toolRollup: ConversationRunToolRollup?

    public init(assistantMessageCount: Int, toolRollup: ConversationRunToolRollup?) {
        self.assistantMessageCount = assistantMessageCount
        self.toolRollup = toolRollup
    }
}

/// Harness-shaped run summary for REST (`GET …/runs`, `GET …/runs/{runId}`).
public enum ConversationRunOutcome: String, Codable, Sendable, Equatable {
    case completed
    case cancelled
    case errored
    case bounded
    case open
}

public struct ConversationRunErrorDetails: Codable, Sendable, Equatable {
    public let `class`: String
    public let message: String

    public init(class: String, message: String) {
        self.class = `class`
        self.message = message
    }
}

public struct ConversationRunInfo: Codable, Sendable, Equatable {
    public let id: UUID
    public let conversationID: UUID
    public let startedAt: Date?
    public let endedAt: Date?
    public let outcome: ConversationRunOutcome
    public let iterationCount: Int
    public let toolCallCount: Int
    public let firstMessageId: String
    public let lastMessageId: String?
    public let cancellationReason: String?
    public let errorDetails: ConversationRunErrorDetails?
    /// Authoritative per-run token totals from persisted completion usage; `nil` when no authoritative usage exists for the run.
    public let tokenRollup: ConversationRunTokenRollup?
    /// Authoritative per-run USD totals from persisted completion usage; `nil` when no authoritative usage exists for the run.
    public let costRollup: ConversationRunCostRollup?
    /// Present when `GET …/runs/{runId}?detail=1` requests transcript-derived rollups.
    public let projectionDetail: ConversationRunProjectionDetail?

    public init(
        id: UUID,
        conversationID: UUID,
        startedAt: Date?,
        endedAt: Date?,
        outcome: ConversationRunOutcome,
        iterationCount: Int,
        toolCallCount: Int,
        firstMessageId: String,
        lastMessageId: String? = nil,
        cancellationReason: String? = nil,
        errorDetails: ConversationRunErrorDetails? = nil,
        tokenRollup: ConversationRunTokenRollup? = nil,
        costRollup: ConversationRunCostRollup? = nil,
        projectionDetail: ConversationRunProjectionDetail? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.iterationCount = max(0, iterationCount)
        self.toolCallCount = max(0, toolCallCount)
        self.firstMessageId = firstMessageId
        self.lastMessageId = lastMessageId
        self.cancellationReason = cancellationReason
        self.errorDetails = errorDetails
        self.tokenRollup = tokenRollup
        self.costRollup = costRollup
        self.projectionDetail = projectionDetail
    }
}

/// Canonical run kind from opening input trust class.
public enum ConversationRunKind: String, Codable, Sendable, Equatable {
    case live
    case trigger
    case channel
    case delegate
}

/// Optional list-runs filter bundle (`GET /conversations/{id}/runs`).
public struct ConversationRunListFilter: Codable, Sendable, Equatable {
    public let kinds: [ConversationRunKind]?
    public let outcomes: [ConversationRunOutcome]?
    public let since: Date?
    public let limit: Int
    public let cursor: String?

    public init(
        kinds: [ConversationRunKind]? = nil,
        outcomes: [ConversationRunOutcome]? = nil,
        since: Date? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) {
        self.kinds = kinds?.isEmpty == true ? nil : kinds
        self.outcomes = outcomes?.isEmpty == true ? nil : outcomes
        self.since = since
        self.limit = min(max(limit, 1), 200)
        self.cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : cursor
    }
}

/// Response for `GET /conversations/{id}/runs`.
public struct ConversationRunListResponse: Codable, Sendable, Equatable {
    public let runs: [ConversationRunInfo]
    public let cursor: String?
    public let total: Int?

    public init(runs: [ConversationRunInfo], cursor: String? = nil, total: Int? = nil) {
        self.runs = runs
        self.cursor = cursor
        self.total = total
    }
}

/// Request body for canonical `POST /conversations/{id}/cancel`.
public struct CancelConversationRunRequest: Codable, Sendable, Equatable {
    public let runId: UUID

    public init(runId: UUID) {
        self.runId = runId
    }
}

/// Success body for canonical `POST /conversations/{id}/cancel`.
public struct CancelConversationRunResponse: Codable, Sendable, Equatable {
    public let runId: UUID
    public let outcome: ConversationRunOutcome

    public init(runId: UUID, outcome: ConversationRunOutcome = .cancelled) {
        self.runId = runId
        self.outcome = outcome
    }
}

public enum CancelConversationRunConflictCode: String, Codable, Sendable, Equatable {
    case runNotInFlight = "run_not_in_flight"
    case runAlreadyEnded = "run_already_ended"
}

/// Conflict body for canonical `POST /conversations/{id}/cancel` failures.
public struct CancelConversationRunConflictBody: Codable, Sendable, Equatable {
    public let code: CancelConversationRunConflictCode
    public let runId: UUID
    public let outcome: ConversationRunOutcome?

    public init(code: CancelConversationRunConflictCode, runId: UUID, outcome: ConversationRunOutcome? = nil) {
        self.code = code
        self.runId = runId
        self.outcome = outcome
    }
}

/// JSON body for `409` when a second append targets a conversation that already has an active run.
public struct ConversationRunConflictBody: Codable, Sendable, Equatable {
    public static let errorCode = "run_in_progress"
    public static let modeChangeRunInProgressCode = "mode_change_run_in_progress"
    public static let modelOrPromptChangeRunInProgressCode = "model_or_prompt_change_run_in_progress"

    public let code: String
    public let conversationID: UUID
    public let activeRunID: UUID

    public init(conversationID: UUID, activeRunID: UUID) {
        self.code = Self.errorCode
        self.conversationID = conversationID
        self.activeRunID = activeRunID
    }

    /// `409` when a mode / phase patch arrives while a streaming run is active for the conversation.
    public init(modeChangeBlocked conversationID: UUID, activeRunID: UUID) {
        self.code = Self.modeChangeRunInProgressCode
        self.conversationID = conversationID
        self.activeRunID = activeRunID
    }

    /// `409` when a model or user prompt patch arrives while a streaming run is active for the conversation.
    public init(modelOrPromptChangeBlocked conversationID: UUID, activeRunID: UUID) {
        self.code = Self.modelOrPromptChangeRunInProgressCode
        self.conversationID = conversationID
        self.activeRunID = activeRunID
    }
}

/// JSON body for `409` when ``expectedPreviousTailHarnessMessageID`` does not match the active transcript tail.
public struct TranscriptTailConflictBody: Codable, Sendable, Equatable {
    public static let errorCode = "transcript_tail_mismatch"

    public let code: String
    public let conversationID: UUID
    public let expectedTailMessageID: UUID
    public let actualTailMessageID: UUID?

    public init(conversationID: UUID, expectedTailMessageID: UUID, actualTailMessageID: UUID?) {
        self.code = Self.errorCode
        self.conversationID = conversationID
        self.expectedTailMessageID = expectedTailMessageID
        self.actualTailMessageID = actualTailMessageID
    }
}

/// JSON body for `409` when ``ConversationPatch/expectedRevision`` does not match ``ModelConversation/controlPlaneRevision``.
public struct ConversationRevisionConflictBody: Codable, Sendable, Equatable {
    public static let errorCode = "revision_mismatch"

    public let code: String
    public let conversationID: UUID
    public let expectedRevision: UInt64
    public let currentRevision: UInt64

    public init(conversationID: UUID, expectedRevision: UInt64, currentRevision: UInt64) {
        self.code = Self.errorCode
        self.conversationID = conversationID
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
    }
}

/// JSON body for `409`/`422` when side-effecting paths require a recorded workspace.
public struct HarnessWorkspaceNotRecordedConflictBody: Codable, Sendable, Equatable {
    public static let errorCode = "harness_workspace_not_recorded"

    public let code: String
    public let conversationID: UUID

    public init(conversationID: UUID) {
        self.code = Self.errorCode
        self.conversationID = conversationID
    }
}
