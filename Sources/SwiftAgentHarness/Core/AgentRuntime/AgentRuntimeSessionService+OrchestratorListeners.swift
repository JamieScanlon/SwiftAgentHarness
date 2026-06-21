import Foundation
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func cancelAgenticOrchestrationSnapshotListeners(for conversationID: UUID) {
        orchestratorListenerTasks.cancelListeners(for: conversationID)
        if activeListenerConversationID == conversationID {
            activeListenerConversationID = nil
        }
    }

    func cancelAllAgenticOrchestrationSnapshotListeners() {
        orchestratorListenerTasks.cancelAllListeners()
        activeListenerConversationID = nil
    }

    func cancelAgenticOrchestrationSnapshotListeners() {
        cancelAllAgenticOrchestrationSnapshotListeners()
    }

    func installAgenticOrchestrationSnapshotListeners<L: OrchestratorListenerServicing>(
        on listener: L,
        conversationID: UUID
    ) {
        activeListenerConversationID = conversationID
        orchestratorListenerTasks.installListeners(
            for: conversationID,
            agenticLoop: Task.detached { [weak listener, conversationID] in
                guard let listener else { return }
                await listener.runAgenticLoopListener(conversationID: conversationID)
            },
            orchestrationSnapshot: Task.detached { [weak listener, conversationID] in
                guard let listener else { return }
                await listener.runOrchestrationSnapshotListener(conversationID: conversationID)
            }
        )
    }

    func installAgenticOrchestrationSnapshotListeners<L: OrchestratorListenerServicing>(on listener: L) {
        guard let conversationID = activeListenerConversationID else { return }
        installAgenticOrchestrationSnapshotListeners(on: listener, conversationID: conversationID)
    }

    func listenerConversationID() -> UUID? {
        activeListenerConversationID
    }
}
