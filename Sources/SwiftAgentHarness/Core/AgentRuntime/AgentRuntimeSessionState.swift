import Foundation
import SwiftAgentKit

struct RunSnapshotKey: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
}

struct AgentRuntimeSessionState {
    var pendingTerminalReasons: [RunSnapshotKey: ConversationRunTerminalReason] = [:]
    var turnStateContinuation: AsyncStream<ConversationOrchestrationState>.Continuation?
    var orchestrationStateOutOfBandPush: (
        id: UUID,
        push: @Sendable (ConversationOrchestrationState) async -> Void
    )?
    var lastOrchestrationOutOfBandWireSnapshot: ConversationOrchestrationState?
    var messageStreamContinuation: AsyncStream<[Message]>.Continuation?
}
