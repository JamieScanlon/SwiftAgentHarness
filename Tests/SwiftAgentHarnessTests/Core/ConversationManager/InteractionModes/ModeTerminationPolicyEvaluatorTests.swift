import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModeTerminationPolicyEvaluator")
struct ModeTerminationPolicyEvaluatorTests {
    @Test("bare-message policy stops on no tool calls")
    func bareMessageStops() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: .neutral,
            termination: ModeProfileTerminationSlice(policy: .bareMessage)
        )
        #expect(result.action == .stop)
        #expect(result.terminalReason?.detail == "bare_message_termination")
    }

    @Test("terminal-tool policy always recovers on bare message")
    func terminalToolRecovers() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: .neutral,
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    rollbackStalledTurn: true,
                    maxAttempts: 2,
                    reminder: .escalating
                )
            )
        )
        #expect(result.action == .recover)
        #expect(result.toolChoiceNext == .required)
        #expect(result.rollbackStalledTurn)
        #expect(result.nextIterationState.consecutiveStalls == 1)
    }

    @Test("terminal-tool recovery bounded after max attempts")
    func terminalToolRecoveryBounded() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: RuntimeTerminationIterationState(consecutiveStalls: 2),
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
        #expect(result.action == .bounded)
        #expect(result.terminalReason?.boundedReason == .maxContinuationRounds)
        #expect(result.terminalReason?.detail == "termination_recovery_exhausted stalls=3 maxAttempts=2")
    }

    @Test("terminal-tool recovery honors rollback disabled setting")
    func terminalToolRecoveryRollbackDisabled() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: .neutral,
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
        #expect(result.action == .recover)
        #expect(result.rollbackStalledTurn == false)
        #expect(result.nextIterationState.consecutiveStalls == 1)
    }

    @Test("terminal-tool tool calls reset consecutive stall counter")
    func toolCallsResetStallCounter() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: true,
            hasHaltingToolCall: false,
            iterationState: RuntimeTerminationIterationState(consecutiveStalls: 5),
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    rollbackStalledTurn: true,
                    maxAttempts: 10,
                    reminder: .escalating
                )
            )
        )
        #expect(result.action == .continueLoop)
        #expect(result.nextIterationState.consecutiveStalls == 0)
    }

    @Test("forced strategy with unsupported model degrades to behavioral (no forced posture)")
    func unsupportedModelDegradesToBehavioral() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: .neutral,
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    rollbackStalledTurn: true,
                    maxAttempts: 10,
                    reminder: .escalating,
                    behavioralInjectAfterStalls: 2
                )
            ),
            supportsForcedToolChoice: false
        )
        #expect(result.action == .recover)
        #expect(result.toolChoiceNext == .auto)
        #expect(result.rollbackStalledTurn == false)
        #expect(result.injectThinkRecovery == false) // first stall is below the injection threshold
        #expect(result.nextIterationState.consecutiveStalls == 1)
    }

    @Test("behavioral recovery injects think once the stall threshold is reached")
    func behavioralInjectsThinkAtThreshold() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: RuntimeTerminationIterationState(consecutiveStalls: 1),
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    maxAttempts: 10,
                    behavioralInjectAfterStalls: 2
                )
            ),
            supportsForcedToolChoice: false
        )
        #expect(result.action == .recover)
        #expect(result.toolChoiceNext == .auto)
        #expect(result.injectThinkRecovery)
        #expect(result.nextIterationState.consecutiveStalls == 2)
    }

    @Test("behavioral-fallback strategy never forces even when the model supports it")
    func behavioralFallbackStrategyNeverForces() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: RuntimeTerminationIterationState(consecutiveStalls: 1),
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .behavioralFallback,
                    maxAttempts: 10,
                    behavioralInjectAfterStalls: 2
                )
            ),
            supportsForcedToolChoice: true
        )
        #expect(result.action == .recover)
        #expect(result.toolChoiceNext == .auto)
        #expect(result.injectThinkRecovery)
    }

    @Test("behavioral recovery still bounds after max attempts")
    func behavioralRecoveryBounded() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: false,
            hasHaltingToolCall: false,
            iterationState: RuntimeTerminationIterationState(consecutiveStalls: 10),
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool,
                recovery: ModeProfileTerminationRecoverySlice(
                    strategy: .forcedToolChoice,
                    maxAttempts: 10,
                    behavioralInjectAfterStalls: 2
                )
            ),
            supportsForcedToolChoice: false
        )
        #expect(result.action == .bounded)
        #expect(result.terminalReason?.boundedReason == .maxContinuationRounds)
    }

    @Test("halting tool call produces stop")
    func haltingToolStops() {
        let result = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: true,
            hasHaltingToolCall: true,
            iterationState: .neutral,
            termination: ModeProfileTerminationSlice(
                policy: .terminalTool
            )
        )
        #expect(result.action == .stop)
    }
}
