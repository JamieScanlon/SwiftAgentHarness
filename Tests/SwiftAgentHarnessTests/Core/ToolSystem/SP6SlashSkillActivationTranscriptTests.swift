import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitSkills
@testable import SwiftAgentHarness

@Suite("SP6 Slash Skill Activation Transcript")
struct SP6SlashSkillActivationTranscriptTests {

    @Test("Synthetic slash skill activation uses tool-result transcript shape")
    func slashActivationTranscriptShape() {
        let toolCallID = "slash-tc-1"
        let body = "demo-skill:\nRun demo steps."
        let assistantCall = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [
                ToolCall(
                    name: SkillsToolProvider.activateToolName,
                    arguments: .object(["skill_name": .string("demo-skill")]),
                    id: toolCallID
                ),
            ]
        )
        let toolResult = Message(
            id: UUID(),
            role: .tool,
            content: body,
            timestamp: Date(),
            toolCalls: [],
            toolCallId: toolCallID
        )
        #expect(assistantCall.toolCalls.first?.name == SkillsToolProvider.activateToolName)
        #expect(toolResult.role == .tool)
        #expect(toolResult.content == body)
        #expect(toolResult.toolCallId == toolCallID)
    }
}
