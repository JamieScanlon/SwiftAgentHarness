import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SystemPromptAssemblyApplicator")
struct SystemPromptAssemblyApplicatorTests {
    @Test("replaces canonical non-harness system message content")
    func replacesCanonicalSystemMessage() {
        let recall = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: "\(HarnessInjectedMessagePrefixes.memoryRecall)\nrecalled"
        )
        let canonicalID = UUID()
        let canonical = Message(id: canonicalID, role: .system, content: "user override", timestamp: Date(), toolCalls: [])
        let user = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let applied = SystemPromptAssemblyApplicator.apply(
            assembledText: "assembled prompt",
            to: [recall, canonical, user]
        )
        #expect(applied[0].content == recall.content)
        #expect(applied[1].id == canonicalID)
        #expect(applied[1].content == "assembled prompt")
        #expect(applied[2].content == "hi")
    }

    @Test("inserts canonical system message when none exists")
    func insertsWhenMissing() {
        let user = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let applied = SystemPromptAssemblyApplicator.apply(assembledText: "assembled prompt", to: [user])
        #expect(applied.count == 2)
        #expect(applied[0].role == .system)
        #expect(applied[0].content == "assembled prompt")
        #expect(applied[1].content == "hi")
        #expect(HarnessInjectedMessageMetadata.isHarnessInjected(applied[0]) == false)
    }

    @Test("userSystemPrompt reads first non-harness system message")
    func extractsUserSystemPrompt() {
        let recall = HarnessInjectedMessageMetadata.systemMessage(id: UUID(), content: "injected")
        let canonical = Message(id: UUID(), role: .system, content: "canonical text", timestamp: Date(), toolCalls: [])
        #expect(SystemPromptAssemblyApplicator.userSystemPrompt(from: [recall, canonical]) == "canonical text")
    }
}
