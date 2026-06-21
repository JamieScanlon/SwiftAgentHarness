import Foundation
import SwiftAgentKit

enum HarnessOrchestrationSupplementBuilder {
    static func build(
        agenticLoopStates: [AgenticLoopID: AgenticLoopState],
        perRequestStates: [LLMRequestID: LLMRequestState]
    ) -> HarnessOrchestrationSupplement? {
        let agentic = OrchestrationStateMapping.pickPrimaryAgenticLoopState(from: agenticLoopStates)
        let milestoneStr = agentic.flatMap { AgentRuntimeLogicalEvent.progressMilestone(for: $0)?.rawValue }

        let terminationCategory: String?
        let terminationDetail: String?
        if OrchestrationStateMapping.anyLLMRequestCancelled(perRequestStates) {
            let w = HarnessTurnTerminationCategory.externalCancellation.wireRepresentation
            terminationCategory = w.category
            terminationDetail = w.detail
        } else if let a = agentic, OrchestrationStateMapping.isTerminalAgentic(a) {
            let c = HarnessTurnTermination.category(forTerminalAgenticState: a)
            let w = c.wireRepresentation
            terminationCategory = w.category
            terminationDetail = w.detail
        } else if !OrchestrationStateMapping.anyLLMRequestInProgress(perRequestStates),
                  let failed = OrchestrationStateMapping.firstTerminalFailedLLMRequestState(from: perRequestStates),
                  let term = HarnessTurnTermination.category(forTerminalRequestState: failed) {
            let w = term.wireRepresentation
            terminationCategory = w.category
            terminationDetail = w.detail
        } else {
            terminationCategory = nil
            terminationDetail = nil
        }

        if milestoneStr == nil && terminationCategory == nil { return nil }
        return HarnessOrchestrationSupplement(
            milestone: milestoneStr,
            terminationCategory: terminationCategory,
            terminationDetail: terminationDetail
        )
    }
}
