import Foundation

protocol OrchestratorListenerServicing: Actor {
    func runAgenticLoopListener(conversationID: UUID) async
    func runOrchestrationSnapshotListener(conversationID: UUID) async
}
