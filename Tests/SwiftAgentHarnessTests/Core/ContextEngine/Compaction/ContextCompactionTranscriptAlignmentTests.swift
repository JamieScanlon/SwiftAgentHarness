import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context compaction transcript alignment")
struct ContextCompactionTranscriptAlignmentTests {
    private func injectedTier1MemoryContext() -> [Message] {
        [
            Message(
                id: UUID(),
                role: .system,
                content: """
\(HarnessInjectedMessagePrefixes.memoryContext)
snapshot
""",
                timestamp: Date(),
                toolCalls: []
            ),
        ]
    }

    private func injectedMemoryMessages() -> [Message] {
        injectedTier1MemoryContext() + [
            Message(
                id: UUID(),
                role: .system,
                content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
recalled
""",
                timestamp: Date(),
                toolCalls: []
            ),
        ]
    }

    private func compressibleThread() -> [Message] {
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<12 {
            let chunk = String(repeating: "z", count: 6_000)
            messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        return messages
    }

    private func makeConversation() -> ModelConversation {
        ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "align-test",
                serverURL: URL(string: "http://localhost:11434")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 200_000
            ),
            messages: [],
            systemPrompt: "sys"
        )
    }

    @Test("partition has no Tier 1 memory prefix when only conversation messages are present")
    func partitionHasNoTier1MemoryPrefix() {
        let thread = compressibleThread()
        let (prefix, transcript) = ContextCompactionCheckpointSupport.partitionForCompaction(thread)
        #expect(prefix.isEmpty)
        #expect(transcript.map(\.id) == thread.map(\.id))
        #expect(!transcript.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.memoryContext) }))
    }

    private func injectedSeniorHarnessPrefix() -> [Message] {
        [
            HarnessInjectedMessageMetadata.systemMessage(
                id: UUID(),
                content: """
\(HarnessInjectedMessagePrefixes.triggerProvenance)
trigger snapshot
"""
            ),
        ]
    }

    @Test("late-placed Tier 2 recall is excluded from compaction transcript")
    func lateRecallExcludedFromCompactionTranscript() {
        let thread = compressibleThread()
        let recall = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
recalled
"""
        )
        guard let lastUserIndex = thread.lastIndex(where: { $0.role == .user }) else {
            Issue.record("expected user message in thread")
            return
        }
        var withLateRecall = thread
        withLateRecall.insert(recall, at: lastUserIndex)
        let (_, transcript) = ContextCompactionCheckpointSupport.partitionForCompaction(withLateRecall)
        #expect(!transcript.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.memoryRecall) }))
        #expect(transcript.filter { $0.role == .user }.count == thread.filter { $0.role == .user }.count)
    }

    @Test("builder rawMiddle matches split on filtered transcript only")
    func builderRawMiddleMatchesFilteredSplit() async throws {
        let injected = injectedSeniorHarnessPrefix()
        let thread = compressibleThread()
        let full = injected + thread
        let conversation = makeConversation()
        let config = ContextCompactionConfiguration.default
        let build = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: ContextCompactionCheckpointSupport.partitionForCompaction(full).transcript,
            conversation: conversation,
            transformMetadata: ContextAssemblyService.conversationTransformMetadata(for: conversation),
            compactionConfig: config,
            enableContextTransform: true,
            lastContextLimitTokens: 200_000,
            lastPromptTokens: 200_000,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .forcedReactiveRetry,
            compactionInjectedPrefix: injected
        )
        guard case .transform(let input) = build else {
            Issue.record("expected transform, got passthrough")
            return
        }
        let rawMiddle = try #require(input.compactionRawMiddleMessages)
        let splitMiddle = ContextCompactionCheckpointSupport.splitForCompaction(
            try #require(input.compactionSplitBaseMessages),
            config: config,
            modelContextLimitTokens: 200_000
        ).middle
        #expect(rawMiddle.map(\.id) == splitMiddle.map(\.id))
        #expect(!rawMiddle.contains(where: { injected.map(\.id).contains($0.id) }))
        #expect(input.compactionInjectedPrefixMessages?.count == 1)
    }

    @Test("transformer prepends injected prefix to split head")
    func transformerPrependsInjectedPrefixToHead() async throws {
        let injected = injectedSeniorHarnessPrefix()
        let thread = compressibleThread()
        let (_, transcript) = ContextCompactionCheckpointSupport.partitionForCompaction(injected + thread)
        let conversation = makeConversation()
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "align",
            fallbackContextLimitTokens: 200_000,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 8,
            middleMinCharactersForCompactionLLM: 0,
            compactionLLMCooldownSeconds: 0,
            compactionToolResultPruneNames: [],
            maxRecentToolResults: 5,
            maxRecentPerNameToolResults: 0,
            compactionSummaryBudgetTokens: 2000,
            compactionCustomInstructionsBlock: "",
            compactionSummarizerContextLimitTokens: 8_000,
            proactiveSafetyBufferTokens: 500,
            proactiveOutputReserveTokens: 500,
            headMinMessageCount: 1,
            tailMinMessageCount: 1,
            tailTokenBudgetFraction: 0.01
        )
        let build = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: transcript,
            conversation: conversation,
            transformMetadata: ContextAssemblyService.conversationTransformMetadata(for: conversation),
            compactionConfig: config,
            enableContextTransform: true,
            lastContextLimitTokens: 200_000,
            lastPromptTokens: 200_000,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .forcedReactiveRetry,
            compactionInjectedPrefix: injected
        )
        guard case .transform(let input) = build else {
            Issue.record("expected transform")
            return
        }
        let transformer = ContextCompactionTransformer(config: config, summarizer: StubAlignmentSummarizer())
        let output = try await transformer.transformContext(input)
        let splitBase = try #require(input.compactionSplitBaseMessages)
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            splitBase,
            config: config,
            modelContextLimitTokens: 200_000
        )
        let injectedIDs = Set(injected.map(\.id))
        let headIDs = Set(output.messages.prefix(injected.count + before.head.count).map(\.id))
        #expect(injectedIDs.isSubset(of: headIDs))
    }
}

private struct StubAlignmentSummarizer: ContextCompactionSummarizing {
    func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
        [Message(id: UUID(), role: .assistant, content: "summary", timestamp: Date(), toolCalls: [])]
    }
}
