import Foundation
import SwiftAgentKit

/// Harness-aligned **logical** labels for agent-loop milestones (communication-layer taxonomy subset).
/// Does not replace SwiftAgentKit types or existing WebSocket JSON; use for internal mapping and future opt-in fields.
enum AgentRuntimeLogicalEventKind: String, Sendable {
    case loopIterationStarted
    case modelCallStarted
    case modelCallCompleted
    case toolCallStarted
    case toolCallCompleted
    case loopIterationCompleted
    case turnCompleted
}

enum AgentRuntimeLogicalEvent {
    /// Progress-only milestones (terminal states return nil — use ``HarnessTurnTermination``).
    static func progressMilestone(for state: AgenticLoopState) -> AgentRuntimeLogicalEventKind? {
        switch state {
        case .started:
            return .loopIterationStarted
        case .llmCall:
            return .modelCallStarted
        case .llmGenerationCompleted:
            return .modelCallCompleted
        case .waitingForToolExecution, .executingTools:
            return .toolCallStarted
        case .betweenIterations:
            return .loopIterationCompleted
        case .completed, .cancelled, .failed, .maxIterationsReached:
            return nil
        }
    }
}
