import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context engine compaction layout contract")
struct ContextEngineCompactionLayoutTests {
    @Test("assemble checkpoint persistence matches transformer output layout contract")
    func assembleCheckpointMatchesLayoutContract() async throws {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = layoutTestConversation()
        let injected = layoutInjectedPrefix()
        let thread = layoutCompressibleThread()
        let full = injected + thread
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            thread,
            config: compactionConfig,
            modelContextLimitTokens: 2_500
        )
        let summaryID = UUID()
        let summary = Message(
            id: summaryID,
            role: .assistant,
            content: "## Active Task\ncompacted summary",
            timestamp: Date(),
            toolCalls: []
        )
        let request = layoutAssembleRequest(
            messages: full,
            conversation: conv,
            compactionConfig: compactionConfig
        )
        let result = await engine.assemble(request: request) { input in
            let output = injected + before.head + [summary] + before.tail
            return ContextTransformOutput(
                messages: output,
                diagnostics: ContextCompactionTransformer.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        let spec = try #require(result.checkpointPersistence)
        #expect(spec.rawMiddleMessageIDs == before.middle.map(\.id))
        #expect(spec.compactedMiddleMessages.map(\.id) == [summaryID])
        #expect(Set(spec.compactedMiddleMessages.map(\.id)).isDisjoint(with: Set(before.head.map(\.id))))
        #expect(Set(spec.compactedMiddleMessages.map(\.id)).isDisjoint(with: Set(before.tail.map(\.id))))
        #expect(Set(spec.compactedMiddleMessages.map(\.id)).isDisjoint(with: Set(injected.map(\.id))))
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            result.messages,
            headCount: injected.count + before.head.count,
            tailCount: before.tail.count
        )
        #expect(slice.map(\.id) == spec.compactedMiddleMessages.map(\.id))
    }

    @Test("assemble with dropped injected prefix yields empty compacted slice")
    func assembleWithDroppedPrefixYieldsEmptySlice() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = layoutTestConversation()
        let injected = layoutInjectedPrefix()
        let thread = layoutCompressibleThread()
        let full = injected + thread
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            thread,
            config: compactionConfig,
            modelContextLimitTokens: 2_500
        )
        let summary = Message(
            id: UUID(),
            role: .assistant,
            content: "## Active Task\ncompacted summary",
            timestamp: Date(),
            toolCalls: []
        )
        let request = layoutAssembleRequest(
            messages: full,
            conversation: conv,
            compactionConfig: compactionConfig
        )
        let result = await engine.assemble(request: request) { _ in
            let output = before.head + [summary] + before.tail
            return ContextTransformOutput(
                messages: output,
                diagnostics: ContextCompactionTransformer.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        let slice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
            result.messages,
            headCount: injected.count + before.head.count,
            tailCount: before.tail.count
        )
        #expect(slice.isEmpty)
    }

    @Test("assemble excludes reinjected messages from checkpoint persistence")
    func assembleExcludesReinjectedFromPersistence() async throws {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = layoutTestConversation()
        let injected = layoutInjectedPrefix()
        let thread = layoutCompressibleThread()
        let full = injected + thread
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        compactionConfig.compactionReinjectionEnabled = true
        compactionConfig.compactionMinPromptTokenSavingsFraction = 0
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            thread,
            config: compactionConfig,
            modelContextLimitTokens: 2_500
        )
        let summaryID = UUID()
        let summary = Message(
            id: summaryID,
            role: .assistant,
            content: "## Active Task\ncompacted summary with plan.md reference",
            timestamp: Date(),
            toolCalls: []
        )
        let reinjectionID = UUID()
        let reinjection = Message(
            id: reinjectionID,
            role: .system,
            content: "[Context reinjection] A plan.md is active for this conversation; use get_plan before large changes.",
            timestamp: Date(),
            toolCalls: []
        )
        let request = layoutAssembleRequest(
            messages: full,
            conversation: conv,
            compactionConfig: compactionConfig
        )
        let result = await engine.assemble(request: request) { _ in
            let output = injected + before.head + [summary, reinjection] + before.tail
            return ContextTransformOutput(
                messages: output,
                diagnostics: ContextCompactionTransformer.summarizedDiagnostic,
                messageProvenance: [
                    ContextTransformMessageProvenance(
                        transformedMessageID: summary.id,
                        origin: .synthesized,
                        sourceMessageIDs: before.middle.map(\.id)
                    ),
                    ContextTransformMessageProvenance(
                        transformedMessageID: reinjection.id,
                        origin: .reinjected,
                        sourceMessageIDs: before.middle.map(\.id)
                    ),
                ]
            )
        }
        let spec = try #require(result.checkpointPersistence)
        #expect(spec.compactedMiddleMessages.map(\.id) == [summaryID])
        #expect(result.messages.contains { $0.id == reinjectionID })
        #expect(result.compactionLowSavings == false)
    }

    @Test("assemble skips persistence when compacted middle exceeds size guards")
    func assembleSkipsPersistenceWhenSizeGuardsFail() async throws {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = layoutTestConversation()
        let injected = layoutInjectedPrefix()
        let thread = layoutCompressibleThread()
        let full = injected + thread
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        compactionConfig.compactionSummaryBudgetTokens = 100
        compactionConfig.compactionMinPromptTokenSavingsFraction = 0
        let before = ContextCompactionCheckpointSupport.splitForCompaction(
            thread,
            config: compactionConfig,
            modelContextLimitTokens: 2_500
        )
        let oversizedSummary = Message(
            id: UUID(),
            role: .assistant,
            content: String(repeating: "Z", count: 1_000),
            timestamp: Date(),
            toolCalls: []
        )
        let request = layoutAssembleRequest(
            messages: full,
            conversation: conv,
            compactionConfig: compactionConfig
        )
        let result = await engine.assemble(request: request) { _ in
            let output = injected + before.head + [oversizedSummary] + before.tail
            return ContextTransformOutput(
                messages: output,
                diagnostics: ContextCompactionTransformer.summarizedDiagnostic,
                messageProvenance: [
                    ContextTransformMessageProvenance(
                        transformedMessageID: oversizedSummary.id,
                        origin: .synthesized,
                        sourceMessageIDs: before.middle.map(\.id)
                    ),
                ]
            )
        }
        #expect(result.checkpointPersistence == nil)
        #expect(result.compactionLowSavings == true)
    }
}

private func layoutTestConversation() -> ModelConversation {
    ModelConversation(
        model: Model(
            protocol: .openAIAPI,
            modelName: "layout-assemble",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 2_500
        ),
        messages: [],
        systemPrompt: "s"
    )
}

private func layoutInjectedPrefix() -> [Message] {
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

private func layoutCompressibleThread() -> [Message] {
    var messages: [Message] = [
        Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
    ]
    let chunk = String(repeating: "x", count: 4_000)
    for idx in 0..<12 {
        messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
    }
    messages.append(Message(id: UUID(), role: .user, content: "latest", timestamp: Date(), toolCalls: []))
    return messages
}

private func layoutAssembleRequest(
    messages: [Message],
    conversation: ModelConversation,
    compactionConfig: ContextCompactionConfiguration
) -> ContextEngineAssembleRequest {
    ContextEngineAssembleRequest(
        messages: messages,
        conversation: conversation,
        phase: .initial,
        gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
        compactionCustomInstructionsOverride: nil,
        enableContextTransform: true,
        compactionConfig: compactionConfig,
        transformMetadata: ConversationTransformMetadata(
            conversationID: conversation.id,
            modelID: conversation.model.id.uuidString,
            modelName: conversation.model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        ),
        lastContextLimitTokens: 2_500,
        lastPromptTokens: nil,
        events: [],
        eventLogFrontier: 0,
        lastLLMDateByConversationID: [:],
        persistCompactionCheckpoint: true,
        allowProactiveCompactionTriggers: true,
        compactionLockAlreadyHeldByCaller: false,
        derivedTailAtProjectionStart: 0
    )
}
