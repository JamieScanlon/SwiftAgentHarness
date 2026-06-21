import Foundation
import SwiftAgentKit

struct TurnLoopPolicyEvaluator {
    struct ContinuationDecision: Sendable {
        let terminalReason: ConversationRunTerminalReason?
        let shouldContinue: Bool
        let shouldRecover: Bool
        let rollbackStalledTurn: Bool
        let toolChoiceNext: RuntimeToolChoicePosture
        let nextTerminationIterationState: RuntimeTerminationIterationState
        let reminder: ModeProfileTerminationRecoveryReminder?
        let injectThinkRecovery: Bool
        let stopLogDetail: String?

        init(
            terminalReason: ConversationRunTerminalReason?,
            shouldContinue: Bool,
            shouldRecover: Bool,
            rollbackStalledTurn: Bool,
            toolChoiceNext: RuntimeToolChoicePosture,
            nextTerminationIterationState: RuntimeTerminationIterationState,
            reminder: ModeProfileTerminationRecoveryReminder?,
            injectThinkRecovery: Bool = false,
            stopLogDetail: String?
        ) {
            self.terminalReason = terminalReason
            self.shouldContinue = shouldContinue
            self.shouldRecover = shouldRecover
            self.rollbackStalledTurn = rollbackStalledTurn
            self.toolChoiceNext = toolChoiceNext
            self.nextTerminationIterationState = nextTerminationIterationState
            self.reminder = reminder
            self.injectThinkRecovery = injectThinkRecovery
            self.stopLogDetail = stopLogDetail
        }
    }

    static func evaluateContinuation(
        conversation: ModelConversation,
        anchorUserMessageID: UUID?,
        hasToolCallsInLatestAssistant: Bool,
        hasHaltingToolCall: Bool,
        terminationIterationState: RuntimeTerminationIterationState,
        stopRequested: Bool,
        continuationsUsed: Int,
        agentHarness: AgentHarnessConfiguration,
        runtimePolicy: ModeProfileRuntimeSlice = .neutral,
        supportsForcedToolChoice: Bool = true
    ) -> ContinuationDecision {
        let heuristicMessages = messagesForHeuristics(
            conversation.messages,
            anchorUserMessageID: anchorUserMessageID
        )

        if stopRequested {
            return ContinuationDecision(
                terminalReason: ConversationRunTerminalReason(
                    category: .externalCancellation,
                    detail: "user_stop_requested"
                ),
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationIterationState,
                reminder: nil,
                stopLogDetail: "user requested stop"
            )
        }
        if hasRunawayEmptyAssistantStreak(heuristicMessages) {
            return ContinuationDecision(
                terminalReason: ConversationRunTerminalReason(
                    category: .boundedStop,
                    boundedReason: .runawayEmptyAssistantStreak
                ),
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationIterationState,
                reminder: nil,
                stopLogDetail: "runaway empty assistant streak"
            )
        }
        if maxRepeatToolCallStreak(in: heuristicMessages, threshold: agentHarness.repeatToolCallStreakThreshold) {
            return ContinuationDecision(
                terminalReason: ConversationRunTerminalReason(
                    category: .boundedStop,
                    boundedReason: .repeatToolCallStreak
                ),
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationIterationState,
                reminder: nil,
                stopLogDetail: "repeated identical tool calls threshold exceeded"
            )
        }
        let chatty = consecutiveChattyAssistantCount(atEndOf: heuristicMessages)
        let chattyHardLimit = agentHarness.effectiveMaxConsecutiveChattyAssistantTurns
        if chatty >= chattyHardLimit {
            return ContinuationDecision(
                terminalReason: ConversationRunTerminalReason(
                    category: .boundedStop,
                    boundedReason: .chattyAssistantLimit
                ),
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationIterationState,
                reminder: nil,
                stopLogDetail: "chatty assistant hard limit exceeded"
            )
        }

        if agentHarness.maxTurnLoopContinuationRounds < Int.max,
           continuationsUsed >= agentHarness.maxTurnLoopContinuationRounds {
            return ContinuationDecision(
                terminalReason: ConversationRunTerminalReason(
                    category: .boundedStop,
                    boundedReason: .maxContinuationRounds
                ),
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationIterationState,
                reminder: nil,
                stopLogDetail: "maxTurnLoopContinuationRounds reached"
            )
        }

        let terminationDecision = ModeTerminationPolicyEvaluator.evaluateTermination(
            hasToolCalls: hasToolCallsInLatestAssistant,
            hasHaltingToolCall: hasHaltingToolCall,
            iterationState: terminationIterationState,
            termination: runtimePolicy.termination,
            supportsForcedToolChoice: supportsForcedToolChoice
        )
        switch terminationDecision.action {
        case .stop:
            let terminal = terminationDecision.terminalReason ?? ConversationRunTerminalReason(
                category: .naturalStop,
                detail: "termination_policy_stop"
            )
            return ContinuationDecision(
                terminalReason: terminal,
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationDecision.nextIterationState,
                reminder: nil,
                stopLogDetail: terminationDecision.stopLogDetail
            )
        case .bounded:
            let terminal = terminationDecision.terminalReason ?? ConversationRunTerminalReason(
                category: .boundedStop,
                boundedReason: .maxContinuationRounds
            )
            return ContinuationDecision(
                terminalReason: terminal,
                shouldContinue: false,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationDecision.nextIterationState,
                reminder: nil,
                stopLogDetail: terminationDecision.stopLogDetail
            )
        case .recover:
            return ContinuationDecision(
                terminalReason: nil,
                shouldContinue: false,
                shouldRecover: true,
                rollbackStalledTurn: terminationDecision.rollbackStalledTurn,
                toolChoiceNext: terminationDecision.toolChoiceNext,
                nextTerminationIterationState: terminationDecision.nextIterationState,
                reminder: terminationDecision.reminder,
                injectThinkRecovery: terminationDecision.injectThinkRecovery,
                stopLogDetail: terminationDecision.stopLogDetail
            )
        case .continueLoop:
            return ContinuationDecision(
                terminalReason: nil,
                shouldContinue: true,
                shouldRecover: false,
                rollbackStalledTurn: false,
                toolChoiceNext: .auto,
                nextTerminationIterationState: terminationDecision.nextIterationState,
                reminder: nil,
                stopLogDetail: nil
            )
        }
    }

    private static func messagesForHeuristics(_ messages: [Message], anchorUserMessageID: UUID?) -> [Message] {
        AgentRuntimeLoopHeuristics.messagesForHeuristics(messages, anchorUserMessageID: anchorUserMessageID)
    }

    private static func consecutiveChattyAssistantCount(atEndOf messages: [Message]) -> Int {
        AgentRuntimeLoopHeuristics.consecutiveChattyAssistantCount(atEndOf: messages)
    }

    private static func hasRunawayEmptyAssistantStreak(_ messages: [Message]) -> Bool {
        AgentRuntimeLoopHeuristics.hasRunawayEmptyAssistantStreak(messages)
    }

    private static func maxRepeatToolCallStreak(in messages: [Message], threshold: Int) -> Bool {
        AgentRuntimeLoopHeuristics.maxRepeatToolCallStreak(in: messages, threshold: threshold)
    }
}
