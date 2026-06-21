import Foundation

enum RuntimeToolChoicePosture: Sendable {
    case auto
    case required
}

struct RuntimeTerminationIterationState: Sendable, Equatable {
    var consecutiveStalls: Int

    static let neutral = RuntimeTerminationIterationState(consecutiveStalls: 0)
}

enum RuntimeTerminationAction: Sendable, Equatable {
    case stop
    case continueLoop
    case recover
    case bounded
}

struct RuntimeTerminationDecision: Sendable {
    let action: RuntimeTerminationAction
    let toolChoiceNext: RuntimeToolChoicePosture
    let rollbackStalledTurn: Bool
    let nextIterationState: RuntimeTerminationIterationState
    let reminder: ModeProfileTerminationRecoveryReminder?
    /// Behavioral recovery: when true the runtime should fabricate a deterministic `think`
    /// tool call this iteration to break a text-only stall on a model that cannot be forced.
    let injectThinkRecovery: Bool
    let terminalReason: ConversationRunTerminalReason?
    let stopLogDetail: String?
}

enum ModeTerminationPolicyEvaluator {
    static func evaluateTermination(
        hasToolCalls: Bool,
        hasHaltingToolCall: Bool,
        iterationState: RuntimeTerminationIterationState,
        termination: ModeProfileTerminationSlice?,
        supportsForcedToolChoice: Bool = true
    ) -> RuntimeTerminationDecision {
        if hasHaltingToolCall {
            return RuntimeTerminationDecision(
                action: .stop,
                toolChoiceNext: .auto,
                rollbackStalledTurn: false,
                nextIterationState: .neutral,
                reminder: nil,
                injectThinkRecovery: false,
                terminalReason: ConversationRunTerminalReason(
                    category: .naturalStop,
                    detail: "terminal_tool_halt_signal"
                ),
                stopLogDetail: "halt signal tool call"
            )
        }
        let policy = termination ?? .bareMessageDefault
        switch policy.policy {
        case .bareMessage:
            if hasToolCalls {
                return RuntimeTerminationDecision(
                    action: .continueLoop,
                    toolChoiceNext: .auto,
                    rollbackStalledTurn: false,
                    nextIterationState: .neutral,
                    reminder: nil,
                    injectThinkRecovery: false,
                    terminalReason: nil,
                    stopLogDetail: nil
                )
            }
            return RuntimeTerminationDecision(
                action: .stop,
                toolChoiceNext: .auto,
                rollbackStalledTurn: false,
                nextIterationState: .neutral,
                reminder: nil,
                injectThinkRecovery: false,
                terminalReason: ConversationRunTerminalReason(
                    category: .naturalStop,
                    detail: "bare_message_termination"
                ),
                stopLogDetail: "bare message termination"
            )
        case .terminalTool:
            if hasToolCalls {
                return RuntimeTerminationDecision(
                    action: .continueLoop,
                    toolChoiceNext: .auto,
                    rollbackStalledTurn: false,
                    nextIterationState: .neutral,
                    reminder: nil,
                    injectThinkRecovery: false,
                    terminalReason: nil,
                    stopLogDetail: nil
                )
            }
            let recovery = policy.recovery ?? ModeProfileTerminationRecoverySlice()
            let attempts = max(1, recovery.maxAttempts)
            let nextStalls = iterationState.consecutiveStalls + 1
            if nextStalls > attempts {
                return RuntimeTerminationDecision(
                    action: .bounded,
                    toolChoiceNext: .auto,
                    rollbackStalledTurn: false,
                    nextIterationState: .neutral,
                    reminder: nil,
                    injectThinkRecovery: false,
                    terminalReason: ConversationRunTerminalReason(
                        category: .boundedStop,
                        boundedReason: .maxContinuationRounds,
                        detail: "termination_recovery_exhausted stalls=\(nextStalls) maxAttempts=\(attempts)"
                    ),
                    stopLogDetail: "termination recovery exhausted :: \(nextStalls) stalls | \(attempts) attempts"
                )
            }
            // Forced tool choice only when the strategy requests it AND the model advertises support;
            // otherwise degrade to behavioral recovery (reminders + `think` injection).
            let useForced = recovery.strategy == .forcedToolChoice && supportsForcedToolChoice
            let injectThink = !useForced && nextStalls >= recovery.behavioralInjectAfterStalls
            return RuntimeTerminationDecision(
                action: .recover,
                toolChoiceNext: useForced ? .required : .auto,
                rollbackStalledTurn: useForced ? recovery.rollbackStalledTurn : false,
                nextIterationState: RuntimeTerminationIterationState(consecutiveStalls: nextStalls),
                reminder: recovery.reminder,
                injectThinkRecovery: injectThink,
                terminalReason: nil,
                stopLogDetail: "terminal tool recovery attempt \(nextStalls) strategy=\(useForced ? "forced" : "behavioral") injectThink=\(injectThink)"
            )
        }
    }
}
