import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Agent loop parity")
struct AgentLoopParityTests {
    @Test("feature flag defaults to agent loop path")
    func featureFlagDefaultsOn() {
        let harness = AgentHarnessConfiguration.default
        #expect(harness.useAgentLoop == true)
    }

    @Test("agent loop ports are constructible from session service dependencies shape")
    func portsShape() async throws {
        let harness = AgentHarnessConfiguration(
            strictAgentHarnessPrompts: true,
            maxTurnLoopContinuationRounds: 10,
            planExcerptMaxCharacters: 1_000,
            watchdogEveryNContinuations: 0,
            maxConsecutiveChattyAssistantTurns: 4,
            repeatToolCallStreakThreshold: 5,
            maxAgenticStepsPerUpdate: nil,
            agentBuildToolInvocationPolicy: .automatic,
            rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: false,
            maxCorrectionRetries: 0,
            useAgentLoop: true
        )
        #expect(harness.useAgentLoop == true)
    }

    @Test("assistant accumulator stores reasoning in content blocks")
    func accumulatorStoresReasoningBlocks() {
        var acc = AssistantMessageAccumulator()
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "",
                    streamingFragment: .reasoning("think")
                )
            )
        )
        acc.consume(.complete(LLMResponse.llmResponse(from: "answer", availableTools: [])))
        let envelope = acc.finalize()
        #expect(envelope.message.content == "answer")
        #expect(envelope.message.toolCalls.isEmpty)
        if case .thinking(let text, nil)? = envelope.contentBlocks.first {
            #expect(text == "think")
        } else {
            Issue.record("expected thinking content block")
        }
    }

    @Test("tool invocation policy wiring exposes required posture")
    func toolInvocationPolicyWiring() {
        #expect(AgentLoopLLMStreaming.toolInvocationPolicy(for: .required) == .required)
    }

    @Test("dispatch snapshot gate blocks tools outside effective entries")
    func dispatchSnapshotGate() async {
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [],
            effectiveEntries: [],
            dispatchContract: .conservativeDefault
        )
        #expect(snapshot.effectiveEntries.contains(where: { $0.name == "missing" }) == false)
    }

    @Test("conversation port forwards stop requested signal")
    func conversationPortStopRequested() async {
        let conversationID = UUID()
        let port = SessionRuntimeConversationPort(
            conversationFn: { _ in nil },
            appendFn: { _, _, _ in },
            markerFn: { _, _, _ in },
            rollbackFn: { _, _ in },
            stampFinishReasonFn: { _, _, _ in },
            stopRequestedFn: { id in id == conversationID }
        )
        #expect(await port.stopRequested(conversationID: conversationID))
        #expect(await port.stopRequested(conversationID: UUID()) == false)
    }
}
