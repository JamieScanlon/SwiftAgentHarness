import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool call streaming policy")
struct ToolCallStreamingPolicyTests {
    @Test("eager mode emits started then argument deltas")
    func eagerModeEmitsDeltas() {
        var state = ToolCallStreamingState(supportsEager: true)
        let first = state.projectDelta(id: "c1", name: "search", argumentsFragment: "{\"q\":")
        #expect(first.count == 2)
        guard case .toolCallStarted? = first[0].streamingFragment else {
            Issue.record("expected toolCallStarted on first eager delta")
            return
        }
        guard case .toolCall(_, _, let args)? = first[1].streamingFragment else {
            Issue.record("expected toolCall fragment")
            return
        }
        #expect(args == "{\"q\":")

        let second = state.projectDelta(id: "c1", name: "search", argumentsFragment: "x\"}")
        #expect(second.count == 1)
        guard case .toolCall(_, _, let args2)? = second[0].streamingFragment else {
            Issue.record("expected toolCall fragment on continuation")
            return
        }
        #expect(args2 == "x\"}")
    }

    @Test("buffered mode suppresses argument deltas")
    func bufferedModeSuppressesArgDeltas() {
        var state = ToolCallStreamingState(supportsEager: false)
        let started = state.projectDelta(id: "c1", name: "search", argumentsFragment: "")
        #expect(started.count == 1)
        guard case .toolCallStarted? = started[0].streamingFragment else {
            Issue.record("expected toolCallStarted")
            return
        }

        let suppressed = state.projectDelta(id: "c1", name: "search", argumentsFragment: "{\"q\":\"x\"}")
        #expect(suppressed.isEmpty)
    }

    @Test("buffered mode emits completed chunks on finalize")
    func bufferedModeEmitsCompletedOnFinalize() {
        var state = ToolCallStreamingState(supportsEager: false)
        let call = ToolCall(
            name: "search",
            arguments: .object(["q": .string("x")]),
            id: "c1"
        )
        let chunks = state.completedChunks(for: [call])
        #expect(chunks.count == 1)
        guard case .toolCallCompleted(let id, let name, let args)? = chunks[0].streamingFragment else {
            Issue.record("expected toolCallCompleted")
            return
        }
        #expect(id == "c1")
        #expect(name == "search")
        #expect(args.contains("q"))
    }

    @Test("provider runtime hooks default eager streaming by provider id")
    func providerDefaultsForEagerStreaming() {
        let anthropicBinding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        let openAIBinding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-4o",
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        #expect(
            ProviderRuntimeHooks.effectiveSupportsEagerToolInputStreaming(
                binding: anthropicBinding,
                compat: nil
            )
        )
        #expect(
            !ProviderRuntimeHooks.effectiveSupportsEagerToolInputStreaming(
                binding: openAIBinding,
                compat: ProviderModelCompat(supportsEagerToolInputStreaming: false)
            )
        )
    }
}
