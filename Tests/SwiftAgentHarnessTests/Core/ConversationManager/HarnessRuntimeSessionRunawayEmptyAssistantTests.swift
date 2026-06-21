import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Unit tests for ``HarnessRuntimeSession/hasRunawayEmptyAssistantStreak(_:)`` (build-phase safety guard).
@Suite("HarnessRuntimeSession — runaway empty assistant (last three messages)")
struct HarnessRuntimeSessionRunawayEmptyAssistantTests {

    private func emptyAssistant() -> Message {
        Message(id: UUID(), role: .assistant, content: "", timestamp: Date(), toolCalls: [])
    }

    private func assistantWithText(_ text: String) -> Message {
        Message(id: UUID(), role: .assistant, content: text, timestamp: Date(), toolCalls: [])
    }

    private func emptyAssistantWithToolCall() -> Message {
        let tc = ToolCall(name: "test_tool", arguments: .object([:]), id: "call-1")
        return Message(id: UUID(), role: .assistant, content: "", timestamp: Date(), toolCalls: [tc])
    }

    private func userMessage(_ text: String) -> Message {
        Message(id: UUID(), role: .user, content: text, timestamp: Date(), toolCalls: [])
    }

    @Test("Trips when last three messages are empty assistants with no tools")
    func tripsWhenLastThreeAreEmptyAssistants() {
        let messages = [
            userMessage("hi"),
            emptyAssistant(),
            emptyAssistant(),
            emptyAssistant(),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == true)
    }

    @Test("Does not trip when an earlier triple of empty assistants is followed by a non-matching tail")
    func doesNotTripWhenEarlierStreakButLastThreeDiffer() {
        let messages = [
            emptyAssistant(),
            emptyAssistant(),
            emptyAssistant(),
            userMessage("stop"),
            assistantWithText("ok"),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == false)
    }

    @Test("Does not trip with fewer than three messages")
    func doesNotTripWhenUnderThreeMessages() {
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak([emptyAssistant(), emptyAssistant()]) == false)
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak([emptyAssistant()]) == false)
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak([]) == false)
    }

    @Test("Does not trip when last assistant has text")
    func doesNotTripWhenLastHasContent() {
        let messages = [
            emptyAssistant(),
            emptyAssistant(),
            assistantWithText("done"),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == false)
    }

    @Test("Does not trip when last message has tool calls")
    func doesNotTripWhenLastHasToolCalls() {
        let messages = [
            emptyAssistant(),
            emptyAssistant(),
            emptyAssistantWithToolCall(),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == false)
    }

    @Test("Does not trip when last three are not all assistant (e.g. user sandwiched)")
    func doesNotTripWhenMiddleIsUser() {
        let messages = [
            emptyAssistant(),
            emptyAssistant(),
            userMessage("?"),
            emptyAssistant(),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == false)
    }

    @Test("Whitespace-only assistant content is treated as empty")
    func whitespaceOnlyCountsAsEmpty() {
        let messages = [
            userMessage("x"),
            Message(id: UUID(), role: .assistant, content: "   \n\t  ", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: " ", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "", timestamp: Date(), toolCalls: []),
        ]
        #expect(HarnessRuntimeSession.hasRunawayEmptyAssistantStreak(messages) == true)
    }
}
