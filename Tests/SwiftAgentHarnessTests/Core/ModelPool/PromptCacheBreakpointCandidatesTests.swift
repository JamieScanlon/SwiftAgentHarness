import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Prompt cache breakpoint candidates")
struct PromptCacheBreakpointCandidatesTests {
    @Test("Stable prefix excludes volatile datetime below cache boundary")
    func stablePrefixExcludesDatetime() {
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        let system = "stable identity block\n\n\(marker)\n\nToday is Friday. Dynamic tools."
        let stable = SystemPromptStablePrefixAnalyzer.stablePrefixText(in: system)
        #expect(stable.contains("stable identity"))
        #expect(stable.contains("Today is ") == false)
    }

    @Test("Harness-injected messages are excluded from derived message count")
    func harnessInjectedExcludedFromMessageCount() {
        let messages = [
            HarnessInjectedMessageMetadata.systemMessage(
                id: UUID(),
                content: "\(HarnessInjectedMessagePrefixes.memoryRecall)\nrecalled"
            ),
            Message(id: UUID(), role: .system, content: "canonical system", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: []),
        ]
        let count = PromptCacheBreakpointCandidates.derivedStablePrefixMessageCount(
            messages: messages,
            breakpoints: [],
            strategy: .automatic
        )
        #expect(count == 3)
    }

    @Test("Tool schema candidate adds token mass beyond messages")
    func toolSchemaCandidateAddsTokenMass() throws {
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://example.com")!,
            priority: 0
        )
        let largeDescription = String(repeating: "x", count: 4000)
        let input = PromptCachePlanningInput(
            modelID: UUID(),
            binding: binding,
            modelCapabilities: [.completion, .promptCacheEphemeral],
            messages: [
                Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: []),
                Message(id: UUID(), role: .user, content: "user", timestamp: Date(), toolCalls: []),
            ],
            config: LLMRequestConfig(
                availableTools: [
                    ToolDefinition(
                        name: "search",
                        description: largeDescription,
                        parameters: [],
                        type: .function
                    )
                ]
            ),
            policy: .enabled(strategy: .automatic)
        )
        let candidates = PromptCacheBreakpointCandidates.build(input: input)
        let tools = try #require(candidates.first { $0.kind == .toolSchemasEnd })
        #expect(tools.estimatedPrefixTokens > 1000)
    }
}
