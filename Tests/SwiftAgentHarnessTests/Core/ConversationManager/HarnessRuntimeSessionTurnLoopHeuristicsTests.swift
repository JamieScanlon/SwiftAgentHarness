import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Ensures build-loop guards (repeat tool, chatty, empty assistant) scope to the current user turn so a new message resets streaks.
@Suite("HarnessRuntimeSession — agent build loop heuristic window")
struct HarnessRuntimeSessionTurnLoopHeuristicsTests {

    private func user(_ id: UUID, _ text: String) -> Message {
        Message(id: id, role: .user, content: text, timestamp: Date(), toolCalls: [])
    }

    private func assistantSameTool() -> Message {
        let tc = ToolCall(name: "get_plan", arguments: .object([:]), id: "c")
        return Message(id: UUID(), role: .assistant, content: "", timestamp: Date(), toolCalls: [tc])
    }

    @Test("Repeat-tool streak ignores assistant tool calls before anchor user message")
    func repeatToolStreakResetsAcrossNewUserTurn() {
        let anchor = UUID()
        let beforeAnchor = (0..<6).map { _ in assistantSameTool() }
        let messages = beforeAnchor + [user(anchor, "continue")] + [assistantSameTool()]

        #expect(
            HarnessRuntimeSession.maxRepeatToolCallStreak(in: messages, threshold: 5) == true
        )

        let window = HarnessRuntimeSession.messagesForTurnLoopHeuristics(messages, anchorUserMessageID: anchor)
        #expect(window.count == 2)
        #expect(
            HarnessRuntimeSession.maxRepeatToolCallStreak(in: window, threshold: 5) == false
        )
    }

    @Test("messagesForTurnLoopHeuristics falls back to full thread when anchor nil")
    func anchorNilUsesFullMessages() {
        let m = [user(UUID(), "hi"), assistantSameTool()]
        let sliced = HarnessRuntimeSession.messagesForTurnLoopHeuristics(m, anchorUserMessageID: nil)
        #expect(sliced.count == m.count)
    }
}
