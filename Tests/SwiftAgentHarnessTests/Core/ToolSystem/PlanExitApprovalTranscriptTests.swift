import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("PlanExitApprovalTranscript")
struct PlanExitApprovalTranscriptTests {
    @Test("rewrites matching pending approval tool results with denial feedback")
    func rewritesPendingByToolCallId() {
        let callID = "exit-call-1"
        let messages = [
            Message(id: UUID(), role: .assistant, content: "", timestamp: Date(), toolCalls: [
                ToolCall(name: ModeTransitionToolProvider.exitPlanModeToolName, arguments: .object([:]), id: callID),
            ]),
            Message(
                id: UUID(),
                role: .tool,
                content: AgentLoopToolDispatch.approvalPendingToolResultContent,
                timestamp: Date(),
                toolCallId: callID
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: AgentLoopToolDispatch.approvalPendingToolResultContent,
                timestamp: Date(),
                toolCallId: "other"
            ),
        ]
        let feedback = PlanApprovalFeedback.deniedToolResultContent(reason: "tighten scope")
        let result = PlanExitApprovalTranscript.rewritingPendingApprovalToolResults(
            in: messages,
            toolCallId: callID,
            content: feedback
        )
        #expect(result.changed == true)
        #expect(result.messages[1].content == feedback)
        #expect(result.messages[2].content == AgentLoopToolDispatch.approvalPendingToolResultContent)
    }

    @Test("without toolCallId rewrites all pending approval sentinels")
    func rewritesAllPendingWhenNoId() {
        let messages = [
            Message(
                id: UUID(),
                role: .tool,
                content: AgentLoopToolDispatch.approvalPendingToolResultContent,
                timestamp: Date(),
                toolCallId: "a"
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: AgentLoopToolDispatch.approvalPendingToolResultContent,
                timestamp: Date(),
                toolCallId: "b"
            ),
        ]
        let feedback = PlanApprovalFeedback.deniedToolResultContent(reason: nil)
        let result = PlanExitApprovalTranscript.rewritingPendingApprovalToolResults(
            in: messages,
            toolCallId: nil,
            content: feedback
        )
        #expect(result.changed == true)
        #expect(result.messages[0].content == feedback)
        #expect(result.messages[1].content == feedback)
    }
}
