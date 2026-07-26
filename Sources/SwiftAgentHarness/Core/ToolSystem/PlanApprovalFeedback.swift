import Foundation

/// Plan-exit approval copy shared by presentation, inline-wait deny, and park-path rewrite.
public enum PlanApprovalFeedback {
    /// Tool-result content when `exit_plan_mode` is denied / request-revision.
    /// Conversation stays in plan; the note (when present) feeds the revision loop.
    public static func deniedToolResultContent(reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "Plan exit rejected — stay in plan mode and revise plan.md before calling exit_plan_mode again.",
        ]
        if let trimmed, !trimmed.isEmpty {
            lines.append("Revision feedback: \(trimmed)")
        } else {
            lines.append("No revision note was provided; ask clarifying questions if needed, then update the plan.")
        }
        return lines.joined(separator: "\n")
    }

    /// Tool-result content when a parked `exit_plan_mode` approval is granted after stop-on-approval.
    public static func approvedAfterParkToolResultContent(targetMode: InteractionMode = .agent) -> String {
        "Plan approved — conversation transitioned toward \(targetMode.rawValue) mode."
    }
}
