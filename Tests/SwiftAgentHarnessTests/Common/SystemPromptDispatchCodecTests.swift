import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SystemPromptDispatchCodec")
struct SystemPromptDispatchCodecTests {
    @Test("harness-injected system messages pass through verbatim")
    func harnessInjectedPassthrough() async throws {
        let recall = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
recalled chunk
"""
        )
        let canonical = Message(id: UUID(), role: .system, content: "user override", timestamp: Date(), toolCalls: [])
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: [recall, canonical],
            systemPrompt: try await SystemPrompt(
                includeCurrentDateTime: false,
                includeAgentSkills: false,
                skillLoader: nil,
                skipConfigLoad: true
            ),
            promptMetadata: [:],
            providerStablePrefix: nil
        )
        let systemBodies = plan.resolvedMessages.filter { $0.role == .system }.map(\.content)
        #expect(systemBodies.count == 2)
        #expect(systemBodies[0] == recall.content)
        #expect(systemBodies[1].contains("# Conversation"))
        #expect(systemBodies[1].contains("user override"))
        #expect(plan.assembledPromptDigest != nil)
    }

    @Test("only first non-harness system message expands canonical template")
    func singleCanonicalExpansion() async throws {
        let first = Message(id: UUID(), role: .system, content: "first", timestamp: Date(), toolCalls: [])
        let second = Message(id: UUID(), role: .system, content: "second", timestamp: Date(), toolCalls: [])
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: [first, second],
            systemPrompt: try await SystemPrompt(
                includeCurrentDateTime: false,
                includeAgentSkills: false,
                skillLoader: nil,
                skipConfigLoad: true
            ),
            promptMetadata: [:],
            providerStablePrefix: nil
        )
        let systemBodies = plan.resolvedMessages.filter { $0.role == .system }.map(\.content)
        #expect(systemBodies.count == 2)
        #expect(systemBodies[0].contains("# Conversation"))
        #expect(systemBodies[0].contains("first"))
        #expect(systemBodies[1] == "second")
    }

    @Test("tier1 memory content lands in canonical Memory section")
    func tier1InMemorySection() async throws {
        let canonical = Message(id: UUID(), role: .system, content: "", timestamp: Date(), toolCalls: [])
        let metadata = [
            SystemPromptAssemblyMetadataKeys.tier1MemoryContent: "frozen project rule",
            "modeMemoryInjection": "on",
        ]
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: [canonical],
            systemPrompt: try await SystemPrompt(
                includeCurrentDateTime: false,
                includeAgentSkills: false,
                skillLoader: nil,
                skipConfigLoad: true
            ),
            promptMetadata: metadata,
            providerStablePrefix: nil
        )
        let text = try #require(plan.canonicalSystemText)
        #expect(text.contains("# Memory"))
        #expect(text.contains("frozen project rule"))
        #expect(text.contains("<!-- provenance: engine:memory -->"))
        #expect(!text.contains("[Memory Context]"))
    }
}
