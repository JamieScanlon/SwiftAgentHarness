import Foundation
import SwiftAgentKit

/// Harness-style termination **category** (priority: cancel > natural > bounded). Used for docs-aligned
/// telemetry and tests; wire payloads remain unchanged.
enum HarnessTurnTerminationCategory: Sendable, Equatable {
    case externalCancellation
    case naturalStop
    case boundedStop(HarnessBoundedStopReason)
    /// Orchestrator or transport failed; not one of the three harness “clean” exits.
    case failure(String?)
}

/// Sub-reasons for harness **bounded** termination (iteration/tool/heuristic limits).
enum HarnessBoundedStopReason: Sendable, Equatable {
    /// SwiftAgentKit agentic hub hit max iterations for this loop.
    case maxAgentIterations
}

enum HarnessTurnTermination {
    /// Classifies SwiftAgentKit terminal agentic states per harness buckets.
    static func category(forTerminalAgenticState state: AgenticLoopState) -> HarnessTurnTerminationCategory {
        switch state {
        case .completed:
            return .naturalStop
        case .cancelled:
            return .externalCancellation
        case .failed(let msg):
            return .failure(msg)
        case .maxIterationsReached:
            return .boundedStop(.maxAgentIterations)
        case .started, .llmCall, .llmGenerationCompleted, .waitingForToolExecution, .executingTools, .betweenIterations:
            preconditionFailure("Non-terminal agentic state passed to category(forTerminal:)")
        }
    }

    /// Classifies LLM request completion when applicable (e.g. cancelled mid-flight).
    static func category(forTerminalRequestState state: LLMRequestState) -> HarnessTurnTerminationCategory? {
        switch state {
        case .cancelled:
            return .externalCancellation
        case .failed:
            return .failure(nil)
        case .completed:
            return nil
        case .queued, .active, .generating, .streaming:
            preconditionFailure("Non-terminal request state")
        }
    }
}

extension HarnessTurnTerminationCategory {
    /// Wire labels for optional ``ConversationOrchestrationState/harness`` (stable string keys).
    var wireRepresentation: (category: String, detail: String?) {
        switch self {
        case .externalCancellation:
            return ("externalCancellation", nil)
        case .naturalStop:
            return ("naturalStop", nil)
        case .boundedStop(let reason):
            switch reason {
            case .maxAgentIterations:
                return ("boundedStop.maxAgentIterations", nil)
            }
        case .failure(let msg):
            return ("failure", msg)
        }
    }
}
