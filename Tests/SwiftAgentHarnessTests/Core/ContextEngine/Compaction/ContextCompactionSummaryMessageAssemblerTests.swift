import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionSummaryMessageAssembler")
struct ContextCompactionSummaryMessageAssemblerTests {
    @Test func emptyTailUsesUserRole() {
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Task done.", tail: [])
        #expect(assembled.messages.count == 1)
        #expect(assembled.messages[0].role == .user)
        #expect(assembled.messages[0].content.contains("REFERENCE ONLY"))
        #expect(assembled.messages[0].content.contains("Task done."))
        #expect(assembled.mergedIntoTail == false)
    }

    @Test func userTailUsesAssistantRole() {
        let tail = [Message(id: UUID(), role: .user, content: "Continue", timestamp: Date(), toolCalls: [])]
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Prior work.", tail: tail)
        #expect(assembled.messages.count == 1)
        #expect(assembled.messages[0].role == .assistant)
        #expect(assembled.mergedIntoTail == false)
    }

    @Test func assistantTailMergesIntoFirstMessage() {
        let tail = [
            Message(id: UUID(), role: .assistant, content: "Partial reply", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "Next", timestamp: Date(), toolCalls: []),
        ]
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Summary body.", tail: tail)
        #expect(assembled.messages.isEmpty)
        #expect(assembled.mergedIntoTail == true)
        #expect(tail[0].content == "Partial reply")
    }
}
