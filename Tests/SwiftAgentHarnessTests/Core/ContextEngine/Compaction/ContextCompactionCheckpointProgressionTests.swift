import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Smoke test for checkpoint progression: first compaction short-circuits (`.pruned`, no summarizer
/// LLM); a persisted `.pruned` checkpoint causes the next run to skip deterministic pruning and
/// invoke the summarizer exactly once, producing `.summarized`.
@Suite("Context compaction checkpoint progression")
struct ContextCompactionCheckpointProgressionTests {
    private actor CountingSummarizer: ContextCompactionSummarizing {
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

    private func shortCircuitCompactionConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "checkpoint-progression-test",
            fallbackContextLimitTokens: 2_500,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15,
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

    /// Transcript with a large listed tool result so deterministic pruning alone drops under the proactive threshold.
    private func buildTranscript() -> [Message] {
        let toolCallID = "tc-prog-1"
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

    /// Every tool message must map to a preceding assistant tool call id; compaction cannot split pairs.
    private func assertToolCallPairIntegrity(_ messages: [Message]) {
        var outstanding: [String: Int] = [:]
        for message in messages {
            if message.role == .assistant {
                for toolCall in message.toolCalls {
                    if let id = toolCall.id, !id.isEmpty {
                        outstanding[id, default: 0] += 1
                    }
                }
            } else if message.role == .tool, let toolCallID = message.toolCallId, !toolCallID.isEmpty {
                #expect((outstanding[toolCallID] ?? 0) > 0, "Tool message without matching assistant tool_call id \(toolCallID)")
                outstanding[toolCallID, default: 0] -= 1
            }
        }
        let leftover = outstanding.filter { $0.value != 0 }
        #expect(leftover.isEmpty, "Unmatched assistant tool_calls: \(leftover)")
    }

    @Test("Pruned short-circuit then pruned checkpoint path invokes summarizer once and ends summarized")
    func prunedThenSummarizedProgression() async throws {
        let cfg = shortCircuitCompactionConfig()
        let summarySynth = Message(
            id: UUID(),
            role: .assistant,
            content: "<summary>handoff</summary>",
            timestamp: Date(),
            toolCalls: []
        )
        let summarizer = CountingSummarizer(output: [summarySynth])
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)

        let model = makeModel()
        let messagesR1 = buildTranscript()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: messagesR1,
            systemPrompt: "sys"
        )
        let meta = metadata(for: conversation)
        let forceGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)

        let build1 = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messagesR1,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            gating: forceGating
        )
        guard case .transform(let input1) = build1 else {
            Issue.record("Expected transform for round 1, got \(build1)")
            return
        }

        let out1 = try await transformer.transformContext(input1)
        #expect(out1.diagnostics == ContextCompactionTransformer.prunedDiagnostic)
        #expect(await summarizer.calls() == 0)
        assertToolCallPairIntegrity(out1.messages)

        let modelLimit = model.maxContextLength ?? cfg.fallbackContextLimitTokens
        let before1 = ContextCompactionCheckpointSupport.splitForCompaction(
            messagesR1,
            config: cfg,
            modelContextLimitTokens: modelLimit
        )
        let compactedMiddle1 = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            out1.messages,
            headCount: before1.head.count,
            tailCount: before1.tail.count
        )
        let fp = ContextCompactionCheckpointSupport.configFingerprint(cfg)
        let checkpointPayload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .pruned,
            coveredMessageIDs: before1.middle.map(\.id),
            syntheticMessages: ContextCompactionCheckpointSupport.syntheticMessagesForPersistence(
                from: compactedMiddle1,
                kind: .pruned
            ),
            configFingerprint: fp,
            basedOnEventID: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let checkpointEvent = CachedConversationEvent(
            conversationID: conversation.id,
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(checkpointPayload),
            createdAt: Date()
        )

        // Round 2: same on-disk view as after round 1; checkpoint is loaded from the event log.
        let build2 = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: out1.messages,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [checkpointEvent],
            eventLogFrontier: 1,
            lastLLMDateByConversationID: [:],
            gating: forceGating
        )
        guard case .transform(let input2) = build2 else {
            Issue.record("Expected transform for round 2, got \(build2)")
            return
        }
        #expect(input2.compactionCheckpointKind == .pruned)

        let out2 = try await transformer.transformContext(input2)
        #expect(out2.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        #expect(await summarizer.calls() == 1)
        assertToolCallPairIntegrity(out2.messages)
    }

    @Test("Summarized checkpoint progression does not double persisted synthetic size each round")
    func summarizedCheckpointProgressionBoundedGrowth() async throws {
        let cfg = summarizedProgressionConfig()
        let summarizer = ProgressiveSizeSummarizer()
        let transformer = ContextCompactionTransformer(config: cfg, summarizer: summarizer)

        let model = makeModel()
        let messagesR1 = buildSummarizedProgressionTranscript()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: messagesR1,
            systemPrompt: "sys"
        )
        let meta = metadata(for: conversation)
        let forceGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let modelLimit = model.maxContextLength ?? cfg.fallbackContextLimitTokens

        let build1 = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messagesR1,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            gating: forceGating
        )
        guard case .transform(let input1) = build1 else {
            Issue.record("Expected transform for round 1, got \(build1)")
            return
        }

        let out1 = try await transformer.transformContext(input1)
        #expect(out1.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        let before1 = ContextCompactionCheckpointSupport.splitForCompaction(
            messagesR1,
            config: cfg,
            modelContextLimitTokens: modelLimit
        )
        let compactedMiddle1 = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            out1.messages,
            headCount: before1.head.count,
            tailCount: before1.tail.count
        )
        let round1Chars = ContextCompactionCheckpointSupport.estimatedMiddleCharacters(compactedMiddle1)
        let round1SummaryBody = try #require(compactedMiddle1.first?.content)
        let fp = ContextCompactionCheckpointSupport.configFingerprint(cfg)
        let syntheticDTOs = before1.middle.map { raw in
            ContextCompactionMessageDTO(
                id: UUID(),
                role: raw.role.rawValue,
                content: round1SummaryBody
            )
        }
        let checkpointPayload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: .summarized,
            coveredMessageIDs: before1.middle.map(\.id),
            syntheticMessages: syntheticDTOs,
            configFingerprint: fp,
            basedOnEventID: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let checkpointEvent = CachedConversationEvent(
            conversationID: conversation.id,
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(checkpointPayload),
            createdAt: Date()
        )

        let messagesR2 = messagesR1 + [
            Message(id: UUID(), role: .user, content: "round-two-user", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "R", count: 8_000),
                timestamp: Date(),
                toolCalls: []
            ),
        ]
        let build2 = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messagesR2,
            conversation: conversation,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: model.maxContextLength,
            lastPromptTokens: nil,
            events: [checkpointEvent],
            eventLogFrontier: 1,
            lastLLMDateByConversationID: [:],
            gating: forceGating
        )
        guard case .transform(let input2) = build2 else {
            Issue.record("Expected transform for round 2, got \(build2)")
            return
        }
        #expect(input2.compactionCheckpointKind == .summarized)

        let out2 = try await transformer.transformContext(input2)
        #expect(out2.diagnostics == ContextCompactionTransformer.summarizedDiagnostic)
        #expect(await summarizer.calls() == 2)

        let before2 = ContextCompactionCheckpointSupport.splitForCompaction(
            messagesR2,
            config: cfg,
            modelContextLimitTokens: modelLimit
        )
        let compactedMiddle2 = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            out2.messages,
            headCount: before2.head.count,
            tailCount: before2.tail.count
        )
        let round2Chars = ContextCompactionCheckpointSupport.estimatedMiddleCharacters(compactedMiddle2)
        #expect(round2Chars < round1Chars * 2)
        assertToolCallPairIntegrity(out2.messages)
    }

    private actor ProgressiveSizeSummarizer: ContextCompactionSummarizing {
        private(set) var callCount = 0

        func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
            callCount += 1
            let size = callCount == 1 ? 500 : 600
            let marker = callCount == 1 ? "A" : "B"
            let content = String(repeating: marker, count: size)
            return [
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: content,
                    timestamp: Date(),
                    toolCalls: []
                ),
            ].prefix(maxMessages).map { $0 }
        }

        func calls() async -> Int { callCount }
    }

    private func summarizedProgressionConfig() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "summarized-progression-test",
            fallbackContextLimitTokens: 2_500,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15,
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
            tailTokenBudgetFraction: 0,
            compactionMinPromptTokenSavingsFraction: 0
        )
    }

    private func buildSummarizedProgressionTranscript() -> [Message] {
        [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "M", count: 8_000),
                timestamp: Date(),
                toolCalls: []
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
    }
}
