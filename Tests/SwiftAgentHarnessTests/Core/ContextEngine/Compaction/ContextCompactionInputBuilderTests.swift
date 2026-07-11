import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionInputBuilder")
struct ContextCompactionInputBuilderTests {
    @Test("Production gating returns passthrough when prompt tokens are well under proactive threshold")
    func underThresholdNoop() {
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        // Make threshold large compared to a "hi"/"yo" payload so the proactive trigger does not fire.
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 20
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: 10_000
        )
        let u = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "yo", timestamp: Date(), toolCalls: [])
        let messages = [u, a]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )
        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: convo,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 10_000,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .production
        )
        guard case .passthrough(let reason) = r else {
            Issue.record("Expected passthrough, got \(r)")
            return
        }
        #expect(reason == "context_compaction_noop_under_token_threshold")
    }

    /// Helper: small conversation with a fixed model + transform metadata.
    private func makeFixture(
        modelContextLimit: Int,
        userContent: String = "hi",
        assistantContent: String = "yo"
    ) -> (cfg: ContextCompactionConfiguration, messages: [Message], conversation: ModelConversation, meta: ConversationTransformMetadata) {
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 20
        cfg.charactersPerToken = 4
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: modelContextLimit
        )
        let u = Message(id: UUID(), role: .user, content: userContent, timestamp: Date(), toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: assistantContent, timestamp: Date(), toolCalls: [])
        let messages = [u, a]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )
        return (cfg, messages, convo, meta)
    }

    @Test("Real lastPromptTokens above threshold fires even when estimate is well under")
    func realCountWinsOverEstimateWhenOver() {
        let f = makeFixture(modelContextLimit: 10_000)
        // proactiveOutputReserve=0, buffer=20 → threshold = 9_980.
        // Estimate path is tiny (a few bytes), but the supplied actual count is above threshold.
        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: f.messages,
            conversation: f.conversation,
            transformMetadata: f.meta,
            compactionConfig: f.cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 10_000,
            lastPromptTokens: 9_999, // above threshold
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .production
        )
        guard case .transform = r else {
            Issue.record("Expected transform input, got \(r)")
            return
        }
    }

    @Test("Real lastPromptTokens just under threshold does not fire even if estimate would")
    func realCountUnderThresholdDominatesLargeEstimate() {
        // Build a config + conversation where the estimate would trigger but the real count would not.
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 0
        cfg.charactersPerToken = 4
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: 1_000
        )
        let big = Message(id: UUID(), role: .user, content: String(repeating: "x", count: 8_000), timestamp: Date(), toolCalls: [])
        let messages = [big]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )

        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: convo,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 1_000,
            lastPromptTokens: 500, // real count well under threshold = 1_000
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .production
        )
        guard case .passthrough(let reason) = r else {
            Issue.record("Expected passthrough when real count is under threshold, got \(r)")
            return
        }
        #expect(reason == "context_compaction_noop_under_token_threshold")
    }

    @Test("Estimate path triggers when lastPromptTokens is nil and content overflows")
    func estimateFiresOnNilLastPromptTokens() {
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 0
        cfg.charactersPerToken = 4
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: 1_000
        )
        let big = Message(id: UUID(), role: .user, content: String(repeating: "x", count: 8_000), timestamp: Date(), toolCalls: [])
        let messages = [big]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )

        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: convo,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 1_000,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: .production
        )
        guard case .transform = r else {
            Issue.record("Expected transform input on estimate path, got \(r)")
            return
        }
    }

    @Test("forceRunCompactionLLM bypasses cooldown gate")
    func forceRunBypassesCooldown() {
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 20
        cfg.compactionLLMCooldownSeconds = 600 // 10-minute cooldown
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: 10_000
        )
        let messages = [
            Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "yo", timestamp: Date(), toolCalls: []),
        ]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )

        // Recent compaction LLM call → would normally trip the cooldown gate.
        let recent = [convo.id: Date()]
        let g = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: convo,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 10_000,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: recent,
            gating: g
        )
        guard case .transform = r else {
            Issue.record("Expected forceRunCompactionLLM to bypass cooldown, got \(r)")
            return
        }
    }

    @Test("ignoreTokenThreshold bypasses under-threshold passthrough when compaction is enabled")
    func ignoreThresholdReachesTransformInput() {
        var cfg = ContextCompactionConfiguration.default
        cfg.enabled = true
        cfg.proactiveOutputReserveTokens = 0
        cfg.proactiveSafetyBufferTokens = 20
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [],
            modelProtocol: .openAIAPI,
            maxContextLength: 10_000
        )
        let u = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "yo", timestamp: Date(), toolCalls: [])
        let messages = [u, a]
        let convo = ModelConversation(
            id: UUID(),
            model: model,
            messages: messages,
            systemPrompt: "s"
        )
        let meta = ConversationTransformMetadata(
            conversationID: convo.id,
            modelID: model.id.uuidString,
            modelName: model.modelName,
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: false,
            reasoningEffort: nil,
            metadata: nil
        )
        let g = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: messages,
            conversation: convo,
            transformMetadata: meta,
            compactionConfig: cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 10_000,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: g
        )
        guard case .transform = r else {
            Issue.record("Expected transform input, got \(r)")
            return
        }
    }

    @Test("Initial-phase input carries resolved deterministic hygiene policy")
    func initialInputThreadsDeterministicHygienePolicy() {
        var fixture = makeFixture(modelContextLimit: 8_000, userContent: String(repeating: "u", count: 6_000), assistantContent: "a")
        fixture.cfg.deterministicToolResultPruningEnabled = false
        fixture.cfg.deterministicAttachmentDocumentHygieneEnabled = true
        fixture.cfg.deterministicMaxImagesPerMessage = 2
        fixture.cfg.deterministicDocumentCharacterThreshold = 777
        fixture.cfg.deterministicDocumentPlaceholder = "[doc-pruned]"
        fixture.cfg.deterministicImagePlaceholder = "[img-pruned]"

        let r = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: fixture.messages,
            conversation: fixture.conversation,
            transformMetadata: fixture.meta,
            compactionConfig: fixture.cfg,
            enableContextTransform: true,
            lastContextLimitTokens: 8_000,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastCompactionLLMDateByConversationID: [:],
            gating: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        )
        guard case .transform(let input) = r else {
            Issue.record("Expected transform input, got \(r)")
            return
        }
        let policy = input.compactionDeterministicHygienePolicy
        #expect(policy?.toolResultPruningEnabled == false)
        #expect(policy?.attachmentDocumentHygiene.enabled == true)
        #expect(policy?.attachmentDocumentHygiene.maxImagesPerMessage == 2)
        #expect(policy?.attachmentDocumentHygiene.documentCharacterThreshold == 777)
        #expect(policy?.attachmentDocumentHygiene.documentPlaceholder == "[doc-pruned]")
        #expect(policy?.attachmentDocumentHygiene.imagePlaceholder == "[img-pruned]")
    }
}
