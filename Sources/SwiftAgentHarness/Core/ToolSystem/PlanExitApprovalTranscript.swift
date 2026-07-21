import Foundation
import SwiftAgentKit

/// Rewrites parked `"Tool execution pending user approval."` tool results after plan-exit resolution.
enum PlanExitApprovalTranscript {
    static func rewritingPendingApprovalToolResults(
        in messages: [Message],
        toolCallId: String?,
        content: String
    ) -> (messages: [Message], changed: Bool) {
        let pending = AgentLoopToolDispatch.approvalPendingToolResultContent
        var out = messages
        var changed = false
        for index in out.indices {
            let message = out[index]
            guard message.role == .tool,
                  message.content == pending
            else { continue }
            if let toolCallId, !toolCallId.isEmpty, message.toolCallId != toolCallId {
                continue
            }
            out[index] = Message(
                id: message.id,
                role: message.role,
                content: content,
                timestamp: message.timestamp,
                images: message.images,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId,
                responseFormat: message.responseFormat,
                inputTrustRaw: message.inputTrustRaw
            )
            changed = true
        }
        return (out, changed)
    }
}
