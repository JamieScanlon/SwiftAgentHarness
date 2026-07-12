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
    var messageStreamContinuation: AsyncStream<[Message]>.Continuation?
}
