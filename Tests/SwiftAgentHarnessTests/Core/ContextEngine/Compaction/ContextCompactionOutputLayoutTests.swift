import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context compaction output layout")
struct ContextCompactionOutputLayoutTests {
    @Test("compactedPortionInOutput extracts middle with injected prefix")
    func compactedPortionInOutputExtractsMiddleWithInjectedPrefix() {
        let prefix = (0..<2).map { i in
            Message(id: UUID(), role: .system, content: "inj\(i)", timestamp: Date(), toolCalls: [])
        }
        let head = [Message(id: UUID(), role: .system, content: "head", timestamp: Date(), toolCalls: [])]
        let middle = [Message(id: UUID(), role: .assistant, content: "compacted", timestamp: Date(), toolCalls: [])]
        let tail = (0..<2).map { i in
            Message(id: UUID(), role: .user, content: "tail\(i)", timestamp: Date(), toolCalls: [])
        }
        let output = prefix + head + middle + tail
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            output,
            headCount: prefix.count + head.count,
            tailCount: tail.count
        )
        #expect(slice.map(\.id) == middle.map(\.id))
    }

    @Test("pruned transformer output matches compaction slice contract")
    func prunedTransformerOutputMatchesCompactionSliceContract() async throws {
        let cfg = layoutTestConfig()
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: StubLayoutSummarizer(output: []))
        let injected = [
            Message(id: UUID(), role: .system, content: "[Memory Context]\nx", timestamp: Date(), toolCalls: []),
        ]
        let toolCallID = "layout-tc-1"
        let transcript: [Message] = [
            Message(id: UUID(), role: .system, content: "s", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "call",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: String(repeating: "X", count: 8_000),
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformContext(
            ContextTransformInput(
                messages: injected + transcript,
                conversation: makeLayoutConversationMetadata(),
                phase: .initial,
                effectiveContextLimitTokens: 2_500,
                compactionCheckpointKind: nil,
                compactionModelContextLimitTokens: 2_500,
                compactionSplitBaseMessages: transcript,
                compactionInjectedPrefixMessages: injected
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.prunedDiagnostic)
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            output.messages,
            headCount: injected.count + before.head.count,
            tailCount: before.tail.count
        )
        let prunedIDs = Set(output.messages.filter { $0.content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder }.map(\.id))
        #expect(!slice.isEmpty)
        #expect(slice.map(\.id) == before.middle.map(\.id))
        #expect(!prunedIDs.isEmpty)
        #expect(prunedIDs.isSubset(of: Set(slice.map(\.id))))
    }

    @Test("summarized transformer output matches compaction slice contract")
    func summarizedTransformerOutputMatchesCompactionSliceContract() async throws {
        let summaryID = UUID()
        let summary = Message(id: summaryID, role: .assistant, content: "## Active Task\nfinish", timestamp: Date(), toolCalls: [])
        var cfg = layoutTestConfig(reinjectionEnabled: false)
        cfg.compactionToolResultPruneNames = []
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: StubLayoutSummarizer(output: [summary]))
        let transcript: [Message] = [
            Message(id: UUID(), role: .system, content: "s", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: String(repeating: "m", count: 8_000), timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a3", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformContext(
            ContextTransformInput(
                messages: transcript,
                conversation: makeLayoutConversationMetadata(),
                phase: .initial,
                effectiveContextLimitTokens: 2_500,
                compactionCheckpointKind: nil,
                compactionModelContextLimitTokens: 2_500,
                compactionSplitBaseMessages: transcript
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            output.messages,
            headCount: before.head.count,
            tailCount: before.tail.count
        )
        #expect(slice.count == 1)
        #expect(slice.first?.content.contains("## Active Task") == true)
        #expect(slice.first?.id == output.messages[before.head.count].id)
    }

    @Test("summarized output with reinjection stamps reinjected provenance and slice excludes reinjection for persistence")
    func summarizedOutputReinjectionProvenanceAndPersistenceSlice() async throws {
        let summaryID = UUID()
        let summary = Message(id: summaryID, role: .assistant, content: "## Active Task\nfinish", timestamp: Date(), toolCalls: [])
        var cfg = layoutTestConfig(reinjectionEnabled: true)
        cfg.compactionToolResultPruneNames = []
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: StubLayoutSummarizer(output: [summary]))
        let transcript: [Message] = [
            Message(id: UUID(), role: .system, content: "s", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1 plan.md", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: String(repeating: "m", count: 8_000), timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformContext(
            ContextTransformInput(
                messages: transcript,
                conversation: makeLayoutConversationMetadata(),
                phase: .initial,
                effectiveContextLimitTokens: 2_500,
                compactionCheckpointKind: nil,
                compactionModelContextLimitTokens: 2_500,
                compactionSplitBaseMessages: transcript
            )
        )
        #expect(output.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let reinjected = output.messageProvenance?.filter { $0.origin == .reinjected } ?? []
        #expect(!reinjected.isEmpty)
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            transcript,
            config: cfg,
            modelContextLimitTokens: 2_500
        )
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            output.messages,
            headCount: before.head.count,
            tailCount: before.tail.count
        )
        let durable = ContextCompactionCheckpointSupport.durableCompactedMiddleForPersistence(
            compactedMiddle: slice,
            messageProvenance: output.messageProvenance
        )
        #expect(durable.count == 1)
        #expect(durable.first?.content.contains("## Active Task") == true)
        #expect(durable.allSatisfy { $0.id != reinjected.first?.transformedMessageID })
    }
}

private struct StubLayoutSummarizer: ContextCompactionSummarizing {
    let output: [Message]

    func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
        Array(output.prefix(maxMessages))
    }
}

private func layoutTestConfig(reinjectionEnabled: Bool = false) -> ContextCompactionConfiguration {
    ContextCompactionConfiguration(
        enabled: true,
        ollamaServerURL: URL(string: "http://localhost:11434")!,
        model: "layout-test",
        fallbackContextLimitTokens: 2_500,
        charactersPerToken: 4,
        maxCompactedMiddleMessages: 15,
        middleMinCharactersForCompactionLLM: 0,
        compactionLLMCooldownSeconds: 0,
        compactionToolResultPruneNames: ["web-fetch"],
        maxRecentToolResults: 5,
        maxRecentPerNameToolResults: 0,
        toolResultPruneReplacementMode: .blankMarker,
        compactionSummaryBudgetTokens: 2000,
        compactionCustomInstructionsBlock: "",
        compactionSummarizerContextLimitTokens: 2_500,
        proactiveSafetyBufferTokens: 500,
        proactiveOutputReserveTokens: 500,
        headMinMessageCount: 1,
        tailMinMessageCount: 1,
        tailTokenBudgetFraction: 0.0001,
        sessionMemorySwapBeforeCompactionEnabled: false,
        compactionReinjectionEnabled: reinjectionEnabled,
        compactionMinPromptTokenSavingsFraction: 0
    )
}

private func makeLayoutConversationMetadata() -> ConversationTransformMetadata {
    ConversationTransformMetadata(
        conversationID: UUID(),
        modelID: "layout",
        modelName: "layout",
        interactionMode: .agent,
        routingPolicyTools: [],
        routingPolicySkills: [],
        thinkingEnabled: false,
        reasoningEffort: nil,
        metadata: nil
    )
}
