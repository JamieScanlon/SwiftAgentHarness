import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Provider prompt cache breakpoint selection")
struct ProviderPromptCacheBreakpointSelectionTests {
    @Test("Anthropic selects stable and rolling breakpoints above thresholds")
    func anthropicSelectsExplicitBreakpoints() {
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://example.com")!,
            priority: 0
        )
        let stableText = String(repeating: "a", count: 12_000)
        let conversationTail = String(repeating: "b", count: 9000)
        let messages = [
            Message(id: UUID(), role: .system, content: stableText, timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "first", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "ok", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: conversationTail, timestamp: Date(), toolCalls: []),
        ]
        let candidates = PromptCacheBreakpointCandidates.build(
            input: PromptCachePlanningInput(
                modelID: UUID(),
                binding: binding,
                modelCapabilities: [.completion, .promptCachePersistent],
                messages: messages,
                config: LLMRequestConfig(),
                policy: .enabled(strategy: .automatic)
            )
        )
        let plan = PromptCacheBreakpointSelectionPolicy.anthropic(
            candidates: candidates,
            context: ProviderPromptCacheBreakpointContext(
                binding: binding,
                capabilities: [.completion, .promptCachePersistent],
                cacheTtlEligibility: .long,
                strategy: .automatic,
                messages: messages
            )
        )
        #expect(plan.mode == .persistent)
        #expect(plan.breakpoints.contains { $0.kind == .stableSystemPrefixEnd })
        #expect(plan.breakpoints.contains { $0.kind == .rollingConversation })
    }

    @Test("Implicit policy returns empty breakpoint plan")
    func implicitReturnsEmptyPlan() {
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "llama",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let plan = PromptCacheBreakpointSelectionPolicy.implicit(
            candidates: [],
            context: ProviderPromptCacheBreakpointContext(
                binding: binding,
                capabilities: [.completion],
                cacheTtlEligibility: .none,
                strategy: .automatic,
                messages: []
            )
        )
        #expect(plan == .empty)
    }

    @Test("LM Studio derives message count without injected inflation")
    func lmStudioDerivedMessageCount() {
        let binding = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "model-x",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 0
        )
        let messages = [
            HarnessInjectedMessageMetadata.systemMessage(
                id: UUID(),
                content: "\(HarnessInjectedMessagePrefixes.triggerProvenance)\ncontext"
            ),
            Message(id: UUID(), role: .system, content: "canonical system", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: []),
        ]
        let candidates = PromptCacheBreakpointCandidates.build(
            input: PromptCachePlanningInput(
                modelID: UUID(),
                binding: binding,
                modelCapabilities: [.completion, .promptCachePersistent],
                messages: messages,
                config: LLMRequestConfig(),
                policy: .enabled(strategy: .automatic)
            )
        )
        let plan = PromptCacheBreakpointSelectionPolicy.lmStudio(
            candidates: candidates,
            context: ProviderPromptCacheBreakpointContext(
                binding: binding,
                capabilities: [.completion, .promptCachePersistent],
                cacheTtlEligibility: .none,
                strategy: .automatic,
                messages: messages
            )
        )
        #expect((plan.stablePrefixMessageCount ?? 0) >= 2)
        #expect(plan.mode != .none)
    }
}
