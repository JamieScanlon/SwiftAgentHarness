import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Run tail stripping")
struct RunTailStrippingTests {
    @Test("partial trailing assistant is stripped while completed turns are preserved")
    func preservesCompletedTurnsStripsPartial() {
        let anchorID = UUID()
        let completedAssistantID = UUID()
        let toolID = UUID()
        let partialAssistantID = UUID()
        let messages: [Message] = [
            Message(id: anchorID, role: .user, content: "go", timestamp: Date(), toolCalls: []),
            Message(
                id: completedAssistantID,
                role: .assistant,
                content: "done step",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "read", arguments: .object([:]), id: "call-1")]
            ),
            Message(id: toolID, role: .tool, content: "ok", timestamp: Date(), toolCalls: [], toolCallId: "call-1"),
            Message(id: partialAssistantID, role: .assistant, content: "  ", timestamp: Date(), toolCalls: [])
        ]

        let preservedID = RunTailStripping.preserveThroughMessageID(
            messages: messages,
            anchorUserMessageID: anchorID
        )

        #expect(preservedID == toolID)
    }

    @Test("completed trailing bare assistant is preserved on cancel strip")
    func preservesCompletedTrailingBareAssistant() {
        let anchorID = UUID()
        let completedAssistantID = UUID()
        let messages: [Message] = [
            Message(id: anchorID, role: .user, content: "go", timestamp: Date(), toolCalls: []),
            Message(
                id: completedAssistantID,
                role: .assistant,
                content: "final answer",
                timestamp: Date(),
                toolCalls: []
            )
        ]

        let preservedID = RunTailStripping.preserveThroughMessageID(
            messages: messages,
            anchorUserMessageID: anchorID
        )

        #expect(preservedID == completedAssistantID)
    }

    @Test("empty trailing bare assistant is still stripped")
    func stripsEmptyTrailingBareAssistant() {
        let anchorID = UUID()
        let partialAssistantID = UUID()
        let messages: [Message] = [
            Message(id: anchorID, role: .user, content: "go", timestamp: Date(), toolCalls: []),
            Message(id: partialAssistantID, role: .assistant, content: "   ", timestamp: Date(), toolCalls: [])
        ]

        let preservedID = RunTailStripping.preserveThroughMessageID(
            messages: messages,
            anchorUserMessageID: anchorID
        )

        #expect(preservedID == anchorID)
    }

    @Test("incomplete tool cycle strips back to last complete boundary")
    func stripsIncompleteToolCycle() {
        let anchorID = UUID()
        let firstToolID = UUID()
        let incompleteAssistantID = UUID()
        let messages: [Message] = [
            Message(id: anchorID, role: .user, content: "go", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "step one",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "read", arguments: .object([:]), id: "call-1")]
            ),
            Message(id: firstToolID, role: .tool, content: "ok", timestamp: Date(), toolCalls: [], toolCallId: "call-1"),
            Message(
                id: incompleteAssistantID,
                role: .assistant,
                content: "step two partial",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "write", arguments: .object([:]), id: "call-2")]
            )
        ]

        let preservedID = RunTailStripping.preserveThroughMessageID(
            messages: messages,
            anchorUserMessageID: anchorID
        )

        #expect(preservedID == firstToolID)
    }
}
