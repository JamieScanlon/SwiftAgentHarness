import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

enum SubAgentDelegateInvocationService {
    static func dispatchModelTurnIfDelegate(
        call: ToolCallRequest,
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        spawnService: SubAgentSpawnService
    ) async -> ToolDispatchOutcome? {
        guard let entry = snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries),
              spawnService.subAgentPool.isDelegateTool(entry: entry) else {
            return nil
        }
        return await spawnService.invokeDelegateToolFromModelTurn(
            call: call,
            conversationID: conversationID,
            runID: runID,
            orchestrator: orchestrator,
            snapshot: snapshot
        )
    }
}
