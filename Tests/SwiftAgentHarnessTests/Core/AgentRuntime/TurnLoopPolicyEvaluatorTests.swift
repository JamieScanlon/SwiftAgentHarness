import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TurnLoopPolicyEvaluator")
struct TurnLoopPolicyEvaluatorTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "policy-eval",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeConversation(messages: [Message], interactionMode: InteractionMode = .agent) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: makeModel(),
            messages: messages,
            turns: [],
            interactionMode: interactionMode
        )
    }

    @Test("evaluateContinuation returns external cancellation when stop requested")
    func evaluateContinuationStopRequested() {
        let conversation = makeConversation(messages: [Message(id: UUID(), role: .assistant, content: "working")])
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: true,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: true,
            continuationsUsed: 0,
            agentHarness: .default,
            runtimePolicy: .neutral
        )
        #expect(decision.shouldContinue == false)
        #expect(decision.terminalReason?.category == .externalCancellation)
        #expect(decision.terminalReason?.detail == "user_stop_requested")
    }

    @Test("evaluateContinuation does not cap when maxTurnLoopContinuationRounds is unlimited")
    func evaluateContinuationUnlimitedRounds() {
        let conversation = makeConversation(messages: [Message(id: UUID(), role: .assistant, content: "still going")])
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: true,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: false,
            continuationsUsed: 10_000,
            agentHarness: .default,
            runtimePolicy: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(policy: .terminalTool)
            )
        )
        #expect(decision.terminalReason?.boundedReason != .maxContinuationRounds)
    }

    @Test("evaluateContinuation returns bounded stop for max continuation rounds")
    func evaluateContinuationMaxRounds() {
        let conversation = makeConversation(messages: [Message(id: UUID(), role: .assistant, content: "still going")])
        let harness = AgentHarnessConfiguration(
            strictAgentHarnessPrompts: true,
            maxTurnLoopContinuationRounds: 10,
            planExcerptMaxCharacters: 6_000,
            watchdogEveryNContinuations: 0,
            maxConsecutiveChattyAssistantTurns: 4,
            repeatToolCallStreakThreshold: 5,
            maxAgenticStepsPerUpdate: nil,
            agentBuildToolInvocationPolicy: .automatic,
            rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: false,
            maxCorrectionRetries: 0
        )
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: true,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: false,
            continuationsUsed: harness.maxTurnLoopContinuationRounds,
            agentHarness: harness,
            runtimePolicy: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(policy: .terminalTool)
            )
        )
        #expect(decision.shouldContinue == false)
        #expect(decision.terminalReason?.boundedReason == .maxContinuationRounds)
    }

    @Test("evaluateContinuation continues when terminal-tool policy allows progress")
    func evaluateContinuationContinuesWithTerminalToolPolicy() {
        let conversation = makeConversation(
            messages: [Message(id: UUID(), role: .assistant, content: "keep going")]
        )
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: true,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: false,
            continuationsUsed: 0,
            agentHarness: .default,
            runtimePolicy: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(policy: .terminalTool)
            )
        )
        #expect(decision.shouldContinue == true)
        #expect(decision.terminalReason == nil)
    }

    @Test("evaluateContinuation marks stalled-turn rollback on terminal-tool recovery")
    func evaluateContinuationRecoveryRollbackEnabled() {
        let conversation = makeConversation(
            messages: [Message(id: UUID(), role: .assistant, content: "no tool calls")]
        )
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: false,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: false,
            continuationsUsed: 0,
            agentHarness: .default,
            runtimePolicy: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(
                    policy: .terminalTool,
                    recovery: ModeProfileTerminationRecoverySlice(
                        strategy: .forcedToolChoice,
                        rollbackStalledTurn: true,
                        maxAttempts: 2,
                        reminder: .off
                    )
                )
            )
        )
        #expect(decision.shouldRecover == true)
        #expect(decision.rollbackStalledTurn == true)
        #expect(decision.toolChoiceNext == .required)
        #expect(decision.nextTerminationIterationState.consecutiveStalls == 1)
    }

    @Test("evaluateContinuation keeps stalled-turn rollback off when disabled")
    func evaluateContinuationRecoveryRollbackDisabled() {
        let conversation = makeConversation(
            messages: [Message(id: UUID(), role: .assistant, content: "no tool calls")]
        )
        let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
            conversation: conversation,
            anchorUserMessageID: nil,
            hasToolCallsInLatestAssistant: false,
            hasHaltingToolCall: false,
            terminationIterationState: .neutral,
            stopRequested: false,
            continuationsUsed: 0,
            agentHarness: .default,
            runtimePolicy: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(
                    policy: .terminalTool,
                    recovery: ModeProfileTerminationRecoverySlice(
                        strategy: .forcedToolChoice,
                        rollbackStalledTurn: false,
                        maxAttempts: 2,
                        reminder: .off
                    )
                )
            )
        )
        #expect(decision.shouldRecover == true)
        #expect(decision.rollbackStalledTurn == false)
        #expect(decision.toolChoiceNext == .required)
        #expect(decision.nextTerminationIterationState.consecutiveStalls == 1)
    }
}
