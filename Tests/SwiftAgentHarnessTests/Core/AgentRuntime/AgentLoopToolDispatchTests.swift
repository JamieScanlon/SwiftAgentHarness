import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Agent loop tool dispatch")
struct AgentLoopToolDispatchTests {
    @Test("tool result message prefers orchestrator toolCallId when request id is nil")
    func toolResultMessagePrefersOrchestratorToolCallId() {
        let result = ToolResult(success: true, content: "ok", toolCallId: "call_generated")
        let call = ToolCallRequest(id: nil, name: "read_file", arguments: .object([:]))
        let linkedID = result.toolCallId ?? call.id
        let message = AgentLoopToolDispatch.toolResultMessage(toolCallId: linkedID, content: result.content)
        #expect(linkedID == "call_generated")
        #expect(message.toolCallId == "call_generated")
    }
}
