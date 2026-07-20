import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context cache TTL pruning")
struct ContextCacheTTLPruningTests {
    private let placeholder = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
    private let referenceInstant = Date(timeIntervalSince1970: 1_700_000_000)
    private let ttl: Double = 300

    private func policy(
        keepRecent: Int = 5,
        targetTools: Set<String>? = nil
    ) -> ContextPruningPolicy {
        ContextPruningPolicy(
            mode: .cacheTTL,
            ttlSeconds: ttl,
            keepRecentToolResults: keepRecent,
            targetTools: targetTools
        )
    }

    private func toolPair(
        toolName: String,
        toolCallID: String,
        resultContent: String,
        timestamp: Date
    ) -> [Message] {
        [
            Message(
                id: UUID(),
                role: .assistant,
                content: "call \(toolName)",
                timestamp: timestamp,
                toolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: resultContent,
                timestamp: timestamp,
                toolCalls: [],
                toolCallId: toolCallID
            ),
        ]
    }

    @Test("TTL gate closed leaves messages unchanged")
    func ttlGateClosed() {
        let old = referenceInstant.addingTimeInterval(-600)
        let messages = [
            Message(id: UUID(), role: .user, content: "user text", timestamp: old, toolCalls: []),
        ] + toolPair(toolName: "read_file", toolCallID: "tc-1", resultContent: "payload", timestamp: old)
        let lastLLM = referenceInstant.addingTimeInterval(-60)
        let result = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(result.transformationKind == .cacheNeutral)
        #expect(result.messages.map(\.content) == messages.map(\.content))
    }

    @Test("TTL gate open substitutes stale tool result content")
    func ttlGateOpenSubstitutesToolResults() {
        let old = referenceInstant.addingTimeInterval(-600)
        let messages = [
            Message(id: UUID(), role: .user, content: "keep me", timestamp: old, toolCalls: []),
        ] + toolPair(toolName: "read_file", toolCallID: "tc-1", resultContent: "stale payload", timestamp: old)
        let lastLLM = referenceInstant.addingTimeInterval(-ttl)
        let result = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 0),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(result.transformationKind == .cacheEditing)
        #expect(result.messages[0].content == "keep me")
        #expect(result.messages[2].content == placeholder)
    }

    @Test("Pair preservation keeps assistant tool_use and trimmed tool_result rows")
    func pairPreservation() {
        let old = referenceInstant.addingTimeInterval(-600)
        let messages = toolPair(
            toolName: "read_file",
            toolCallID: "tc-pair",
            resultContent: "stale payload",
            timestamp: old
        )
        let lastLLM = referenceInstant.addingTimeInterval(-ttl)
        let result = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 0),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(result.messages[0].role == .assistant)
        #expect(result.messages[0].toolCalls.contains { $0.id == "tc-pair" })
        #expect(result.messages[1].role == .tool)
        #expect(result.messages[1].toolCallId == "tc-pair")
        #expect(result.messages[1].content == placeholder)
    }

    @Test("keepRecentToolResults protects the last N tool results even when old")
    func keepRecentToolResults() {
        let old = referenceInstant.addingTimeInterval(-600)
        var messages: [Message] = []
        for index in 0..<3 {
            messages += toolPair(
                toolName: "read_file",
                toolCallID: "tc-\(index)",
                resultContent: "payload-\(index)",
                timestamp: old.addingTimeInterval(Double(index))
            )
        }
        let lastLLM = referenceInstant.addingTimeInterval(-ttl)
        let result = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 1),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(result.messages[1].content == placeholder)
        #expect(result.messages[3].content == placeholder)
        #expect(result.messages[5].content == "payload-2")
    }

    @Test("targetTools limits substitution to named tools")
    func targetToolsFilter() {
        let old = referenceInstant.addingTimeInterval(-600)
        let messages = toolPair(
            toolName: "read_file",
            toolCallID: "tc-read",
            resultContent: "read payload",
            timestamp: old
        ) + toolPair(
            toolName: "web_search",
            toolCallID: "tc-search",
            resultContent: "search payload",
            timestamp: old
        )
        let lastLLM = referenceInstant.addingTimeInterval(-ttl)
        let result = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 0, targetTools: ["read_file"]),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(result.messages[1].content == placeholder)
        #expect(result.messages[3].content == "search payload")
    }

    @Test("Deterministic referenceInstant and pruning output do not depend on wall clock")
    func determinism() {
        let old = referenceInstant.addingTimeInterval(-600)
        let messages = toolPair(
            toolName: "read_file",
            toolCallID: "tc-det",
            resultContent: "payload",
            timestamp: old
        )
        let lastLLM = referenceInstant.addingTimeInterval(-ttl)
        let first = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 0),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        let second = ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy(keepRecent: 0),
            lastLLMDate: lastLLM,
            referenceInstant: referenceInstant,
            toolCallResolutionContext: messages
        )
        #expect(first.messages.map(\.content) == second.messages.map(\.content))
        #expect(ContextCacheTTLPruning.deterministicReferenceInstant(from: messages) == old)
    }

    @Test("Resolver maps cacheAwarePruningEnabled to cacheTTL mode")
    func resolverBackwardCompatibility() {
        var config = ContextCompactionConfiguration.default
        config.cacheAwarePruningEnabled = true
        config.cachePruningTTLSeconds = 120
        let resolved = ContextPruningPolicyResolver.resolve(config: config)
        #expect(resolved.mode == .cacheTTL)
        #expect(resolved.ttlSeconds == 120)
    }

    @Test("Resolver uses provider TTL when config TTL is unset")
    func resolverProviderTTL() {
        var config = ContextCompactionConfiguration.default
        config.contextPruningMode = "cacheTTL"
        let short = ContextPruningPolicyResolver.resolve(config: config, providerEligibility: .short)
        let long = ContextPruningPolicyResolver.resolve(config: config, providerEligibility: .long)
        #expect(short.ttlSeconds == 300)
        #expect(long.ttlSeconds == 3600)
    }

    @Test("Assemble integration substitutes stale tool bytes when TTL expired")
    func assembleIntegration() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conversationID = UUID()
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "cache-ttl-prune",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        conversation.id = conversationID
        let old = referenceInstant.addingTimeInterval(-600)
        let toolCallID = "assemble-tc"
        let messages = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: old, toolCalls: []),
            Message(id: UUID(), role: .user, content: "user words", timestamp: old, toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "tool call",
                timestamp: old,
                toolCalls: [ToolCall(name: "read_file", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "stale tool bytes",
                timestamp: old,
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "recent", timestamp: referenceInstant, toolCalls: []),
        ]
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.contextPruningMode = "cacheTTL"
        compactionConfig.cachePruningTTLSeconds = ttl
        compactionConfig.contextPruningKeepRecentToolResults = 0
        let pruningPolicy = ContextPruningPolicyResolver.resolve(config: compactionConfig)
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: false,
            compactionConfig: compactionConfig,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conversationID,
                modelID: conversation.model.id.uuidString,
                modelName: conversation.model.modelName,
                interactionMode: conversation.interactionMode,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: nil,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastModelRequestAtByConversationID: [conversationID: referenceInstant.addingTimeInterval(-ttl)],
            lastCompactionLLMDateByConversationID: [:],
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: false,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            projectionPolicy: ContextEngineProjectionPolicyInput(contextPruningPolicy: pruningPolicy)
        )
        let assembled = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let toolMessage = assembled.messages.first { $0.role == .tool && $0.toolCallId == toolCallID }
        #expect(toolMessage?.content == placeholder)
        #expect(assembled.messages.contains { $0.role == .user && $0.content == "user words" })
    }
}
