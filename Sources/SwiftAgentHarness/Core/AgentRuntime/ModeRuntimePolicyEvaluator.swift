import Foundation

enum ModeRuntimePolicyEvaluator {
    static func stopOnApprovalTerminalReason(
        runtime: ModeProfileRuntimeSlice,
        hasApprovalRequiredTools: Bool
    ) -> ConversationRunTerminalReason? {
        guard runtime.stopOnApprovalRequest == true, hasApprovalRequiredTools else {
            return nil
        }
        return ConversationRunTerminalReason(
            category: .naturalStop,
            detail: "stop_on_approval_request"
        )
    }
}
