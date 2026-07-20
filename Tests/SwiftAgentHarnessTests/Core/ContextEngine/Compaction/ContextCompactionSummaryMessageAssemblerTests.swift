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
        #expect(assembled.persistenceSummary?.role == .user)
        #expect(assembled.persistenceSummary?.content == assembled.messages[0].content)
    }

    @Test func userTailUsesAssistantRole() {
        let tail = [Message(id: UUID(), role: .user, content: "Continue", timestamp: Date(), toolCalls: [])]
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Prior work.", tail: tail)
        #expect(assembled.messages.count == 1)
        #expect(assembled.messages[0].role == .assistant)
        #expect(assembled.mergedIntoTail == false)
        #expect(assembled.persistenceSummary?.role == .assistant)
        #expect(assembled.persistenceSummary?.content == assembled.messages[0].content)
    }

    @Test func assistantTailMergesIntoFirstMessage() throws {
        let tail = [
            Message(id: UUID(), role: .assistant, content: "Partial reply", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "Next", timestamp: Date(), toolCalls: []),
        ]
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Summary body.", tail: tail)
        #expect(assembled.messages.isEmpty)
        #expect(assembled.mergedIntoTail == true)
        #expect(tail[0].content == "Partial reply")
        let mergedTail = assembled.mergedTail
        #expect(mergedTail != nil)
        #expect(mergedTail?.count == 2)
        #expect(mergedTail?[0].id == tail[0].id)
        #expect(mergedTail?[0].content.contains("REFERENCE ONLY") == true)
        #expect(mergedTail?[0].content.contains("Summary body.") == true)
        #expect(mergedTail?[0].content.contains("Partial reply") == true)
        #expect(mergedTail?[1].id == tail[1].id)
        #expect(mergedTail?[1].content == tail[1].content)
        let persistence = try #require(assembled.persistenceSummary)
        #expect(persistence.role == .assistant)
        #expect(persistence.content.contains("REFERENCE ONLY"))
        #expect(persistence.content.contains("Summary body."))
        #expect(persistence.content.contains("Partial reply") == false)
    }

    @Test("assistant-first tail with later user still merges and retains that user turn")
    func assistantFirstTailWithLaterUserRetainsUser() throws {
        let userID = UUID()
        let tail = [
            Message(id: UUID(), role: .assistant, content: "Partial reply", timestamp: Date(), toolCalls: []),
            Message(id: userID, role: .user, content: "run-anchor prompt", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "follow-up", timestamp: Date(), toolCalls: []),
        ]
        let assembled = ContextCompactionSummaryMessageAssembler.assemble(summaryBody: "Prior work.", tail: tail)
        #expect(assembled.mergedIntoTail == true)
        let mergedTail = try #require(assembled.mergedTail)
        #expect(mergedTail.contains(where: { $0.id == userID && $0.content == "run-anchor prompt" }))
        #expect(RenderableMessageInvariant.isRenderableUserQuery(mergedTail.first(where: { $0.id == userID })!))
    }
}
