import Foundation
import SwiftAgentKit

struct RunSnapshotKey: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
}

struct AgentRuntimeSessionState {
    var pendingTerminalReasons: [RunSnapshotKey: ConversationRunTerminalReason] = [:]
    var turnStateContinuation: AsyncStream<ConversationOrchestrationState>.Continuation?
    var orchestrationStateTopicRefreshHandler: (@Sendable (UUID, ConversationOrchestrationState) async -> Void)?
    var lastTopicRefreshOrchestrationSnapshot: ConversationOrchestrationState?
    /// Per-conversation, unlike ``lastTopicRefreshOrchestrationSnapshot``, which is a single slot
    /// owned by whichever conversation is currently streaming. A delegate finishing on an idle
    /// conversation must not disturb that slot. Absent means `.idle`, so the map only holds
    /// conversations with live delegate activity and drains as they finish.
    var lastPublishedSubAgentActivityPhaseByConversationID: [UUID: ConversationSubAgentActivityPhase] = [:]
    var messageStreamContinuation: AsyncStream<[Message]>.Continuation?
}
