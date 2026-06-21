import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Phase D: full compaction path (builder + transformer) must keep assistant `tool_calls` and tool
/// messages paired by `toolCallId` so the agent loop stays valid.
@Suite("Context compaction tool-pair E2E")
struct ContextCompactionToolPairE2ETests {
    private actor FixedSummarizer: ContextCompactionSummarizing {
        private(set) var callCount = 0
        private let output: [Message]

        init(output: [Message]) {
            self.output = output
        }

        func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
            callCount += 1
            return Array(output.prefix(maxMessages))
        }

        func calls() async -> Int { callCount }
    }

    private func toolPairConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "tool-pair-e2e",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15,
            toolResultSummarizationCharacterThreshold: 1_000_000,
            middleMinCharactersForCompactionLLM: 0,
            compactionLLMCooldownSeconds: 0,
            compactionToolResultPruneNames: ["web-fetch"],
            maxRecentToolResults: 5,
            maxRecentPerNameToolResults: 0,
            compactionSummaryBudgetTokens: 2000,
            compactionCustomInstructionsBlock: "",
            compactionSummarizerContextLimitTokens: 2_500,
            proactiveSafetyBufferTokens: 500,
            proactiveOutputReserveTokens: 500,
            headMinMessageCount: 1,
            tailMinMessageCount: 1,
            tailTokenBudgetFraction: 0
        )
    }

    private func summarizedToolPairConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "tool-pair-e2e-summarized",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15,
            toolResultSummarizationCharacterThreshold: 1_000_000,
            middleMinCharactersForCompactionLLM: 0,
            compactionLLMCooldownSeconds: 0,
            compactionToolResultPruneNames: [],
            maxRecentToolResults: 5,
            maxRecentPerNameToolResults: 0,
            compactionSummaryBudgetTokens: 2000,
            compactionCustomInstructionsBlock: "",
            compactionSummarizerContextLimitTokens: 2_500,
            proactiveSafetyBufferTokens: 500,
            proactiveOutputReserveTokens: 500,
            headMinMessageCount: 1,
            tailMinMessageCount: 1,
            tailTokenBudgetFraction: 0
        )
    }

    private func makeModel(maxContext: Int = 2_500) -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: maxContext
        )
    }

    private func metadata(for conversation: ModelConversation) -> ConversationTransformMetadata {
        ConversationTransformMetadata(
            conversationID: conversation.id,
            modelID: conversation.model.id.uuidString,
            modelName: conversation.model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )
    }

    /// Build transcript whose middle contains assistant(tool_calls) + tool + oversized prune target (same pattern as checkpoint progression).
    private func buildTranscriptWithToolPair() -> [Message] {
        let toolCallID = "tc-toolpair-1"
        let toolAssistant = Message(
            id: UUID(),
            role: .assistant,
            content: "fetching",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
        )
        let bigTool = Message(
            id: UUID(),
            role: .tool,
            content: String(repeating: "P", count: 8_000),
            timestamp: Date(),
            toolCalls: [],
            toolCallId: toolCallID
        )
        // Must match multi-user layout from checkpoint progression tests: ≥3 user turns so `splitForCompaction`
        // keeps a non-empty middle (tool assistant + tool live in the middle band).
        return [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            toolAssistant,
            bigTool,
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
    }

    private func buildTranscriptWithMultiToolCallPair() -> [Message] {
        let firstCallID = "tc-toolpair-multi-1"
        let secondCallID = "tc-toolpair-multi-2"
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "calling two tools",
            timestamp: Date(),
            toolCalls: [
                ToolCall(name: "web-fetch", arguments: .object([:]), id: firstCallID),
                ToolCall(name: "get_plan", arguments: .object([:]), id: secondCallID),
            ]
        )
        let firstTool = Message(
            id: UUID(),
            role: .tool,
            content: String(repeating: "A", count: 4_000),
            timestamp: Date(),
            toolCalls: [],
            toolCallId: firstCallID
        )
        let secondTool = Message(
            id: UUID(),
            role: .tool,
            content: String(repeating: "B", count: 4_000),
            timestamp: Date(),
            toolCalls: [],
            toolCallId: secondCallID
        )
        return [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            assistant,
            firstTool,
            secondTool,
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
    }

    /// Every tool message must reference a preceding assistant `tool_calls` id; counts must balance (OpenAI-style pairing).
    private func assertToolCallPairIntegrity(_ messages: [Message]) {
        var outstanding: [String: Int] = [:]
        for m in messages {
            if m.role == .assistant {
                for tc in m.toolCalls {
                    if let id = tc.id, !id.isEmpty {
                        outstanding[id, default: 0] += 1
                    }
                }
            } else if m.role == .tool, let tid = m.toolCallId, !tid.isEmpty {
                #expect((outstanding[tid] ?? 0) > 0, "Tool message without matching assistant tool_call id \(tid)")
                outstanding[tid, default: 0] -= 1
            }
        }
        let leftover = outstanding.filter { $0.value != 0 }
        #expect(leftover.isEmpty, "Unmatched assistant tool_calls: \(leftover)")
    }

    @Test("Pruned compaction path preserves tool call / tool result pairing")
    func prunedCompactionPreservesToolPairs() async throws {
        let cfg = toolPairConfig()
        let transformer = ContextCompactionTransformer(config: cfg)
        let model = makeModel()
        let messages = buildTranscriptWithToolPair()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "sys"
        )
        let meta = metadata(for: conversation)
        let gating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)

        let build = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            gating: gating
        )
        guard case .transform(let input) = build else {
            Issue.record("Expected .transform, got \(build)")
            return
        }

        let out = try await transformer.transformContext(input)
        #expect(out.diagnostics == ContextCompactionTransformer.prunedDiagnostic)
        assertToolCallPairIntegrity(out.messages)
    }

    @Test("Pruned compaction path preserves multi-tool call pairing")
    func prunedCompactionPreservesMultiToolPairs() async throws {
        let cfg = toolPairConfig()
        let transformer = ContextCompactionTransformer(config: cfg)
        let model = makeModel()
        let messages = buildTranscriptWithMultiToolCallPair()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "sys"
        )
        let meta = metadata(for: conversation)
        let gating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let build = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            gating: gating
        )
        guard case .transform(let input) = build else {
            Issue.record("Expected .transform, got \(build)")
            return
        }
        let out = try await transformer.transformContext(input)
        #expect(out.diagnostics == ContextCompactionTransformer.prunedDiagnostic)
        assertToolCallPairIntegrity(out.messages)
    }

    @Test("Summarized compaction path preserves tool-pair closure")
    func summarizedCompactionPreservesToolPairs() async throws {
        let cfg = summarizedToolPairConfig()
        let syntheticSummary = Message(
            id: UUID(),
            role: .assistant,
            content: "<summary>tool-pair-preserved</summary>",
            timestamp: Date(),
            toolCalls: []
        )
        let summarizer = FixedSummarizer(output: [syntheticSummary])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)
        let model = makeModel()
        let messages = buildTranscriptWithToolPair()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "sys"
        )
        let meta = metadata(for: conversation)
        let gating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let build = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            gating: gating
        )
        guard case .transform(let input) = build else {
            Issue.record("Expected .transform, got \(build)")
            return
        }
        let out = try await transformer.transformContext(input)
        #expect(out.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        #expect(await summarizer.calls() == 1)
        assertToolCallPairIntegrity(out.messages)
    }
}
