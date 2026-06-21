import Foundation

/// Optimistic concurrency mismatch on append for the raw or derived journal stream (`CachedConversationEvent.streamSequence`).
struct JournalStreamSequenceConflict: Error, Sendable {
    let stream: ConversationJournalStream
    let expected: Int
    let actual: Int
}

/// Errors shared by orchestration/runtime wiring and conversation resource + persistence paths.
enum ConversationServiceError: Error, Sendable, Equatable {
    case containerNotFound
    case conversationNotFound
    case modelNotFound
    /// Model was removed from Ollama/LMStudio; conversation is read-only
    case modelUnavailable
    case failedToSaveContext
    case noModelSelected
    case failedToInitialize
    /// Revert target id is missing, not a user message, or not in the current conversation.
    case invalidRevertTarget
    case conversationReplayAlreadyRunning
    /// ``updateConversationModelAndUserPrompt`` was called with no effective model or prompt change.
    case noMeaningfulModelOrPromptChange
    /// A second append was attempted while this conversation already had an active streaming run.
    case conversationRunInProgress(conversationID: UUID, activeRunID: UUID)
    /// Interaction mode cannot change while this conversation has an active streaming run.
    case conversationModeChangeRunInProgress(conversationID: UUID, activeRunID: UUID)
    /// A configured mode transition hook id is unknown to the runtime hook registry.
    case modeTransitionHookUnavailable(hookID: String)
    /// ``cancelRun`` did not match the active run (or run already finished).
    case cancelRunNotActive
    /// Optional tail precondition on user message append did not match the persisted active transcript tail.
    case transcriptTailMismatch(conversationID: UUID, expectedTailMessageID: UUID, actualTailMessageID: UUID?)
    /// ``ConversationPatch/expectedRevision`` did not match persisted ``ModelConversation/controlPlaneRevision``.
    case conversationRevisionMismatch(conversationID: UUID, expectedRevision: UInt64, currentRevision: UInt64)
    /// ``SubAgentSpawnRequest`` missing required fields (e.g. fork without ``userMessageID``).
    case invalidSubAgentSpawn
    /// Runtime lane admission rejected due to capacity/fanout/session constraints.
    case runtimeLaneUnavailable(reason: String)
}

extension ConversationServiceError: APILayerConversationRouteErrorRepresenting {
    var apiLayerConversationRouteError: APILayerConversationRouteError? {
        switch self {
        case .conversationNotFound:
            return .conversationNotFound
        case .invalidRevertTarget:
            return .invalidRevertTarget
        case .cancelRunNotActive:
            return .cancelRunNotActive
        default:
            return nil
        }
    }
}

extension ConversationServiceError: APILayerRESTConflictRepresenting {
    var apiLayerRESTConflictBody: Data? {
        switch self {
        case let .transcriptTailMismatch(conversationID, expectedTailMessageID, actualTailMessageID):
            return try? JSONEncoder().encode(
                TranscriptTailConflictBody(
                    conversationID: conversationID,
                    expectedTailMessageID: expectedTailMessageID,
                    actualTailMessageID: actualTailMessageID
                )
            )
        case let .conversationRunInProgress(conversationID, activeRunID):
            return try? JSONEncoder().encode(
                ConversationRunConflictBody(
                    conversationID: conversationID,
                    activeRunID: activeRunID
                )
            )
        case let .conversationModeChangeRunInProgress(conversationID, activeRunID):
            return try? JSONEncoder().encode(
                ConversationRunConflictBody(
                    modeChangeBlocked: conversationID,
                    activeRunID: activeRunID
                )
            )
        case let .conversationRevisionMismatch(conversationID, expectedRevision, currentRevision):
            return try? JSONEncoder().encode(
                ConversationRevisionConflictBody(
                    conversationID: conversationID,
                    expectedRevision: expectedRevision,
                    currentRevision: currentRevision
                )
            )
        case let .runtimeLaneUnavailable(reason):
            return try? JSONEncoder().encode(["code": "runtime_lane_unavailable", "reason": reason])
        default:
            return nil
        }
    }
}
