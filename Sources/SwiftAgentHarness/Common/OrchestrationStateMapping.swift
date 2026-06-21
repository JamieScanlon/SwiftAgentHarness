import Foundation
import SwiftAgentKit

/// Maps orchestration snapshots into ``ConversationOrchestrationState`` fields and picks deterministic phases when multiple loops/requests exist.
enum OrchestrationStateMapping {
    static func stableAgenticLoopSortKey(_ id: AgenticLoopID) -> String {
        switch id {
        case .a2a(let taskId, let contextId):
            return "a2a:\(taskId):\(contextId)"
        case .orchestratorSession(let uuid):
            return "orch:\(uuid.uuidString)"
        }
    }

    static func pickAgenticPhase(
        from states: [AgenticLoopID: AgenticLoopState],
        fallback: ConversationAgenticPhase
    ) -> ConversationAgenticPhase {
        guard !states.isEmpty else { return fallback }
        let orderedEntries = states.sorted { stableAgenticLoopSortKey($0.key) < stableAgenticLoopSortKey($1.key) }
        let inProgressEntries = orderedEntries.filter { isAgenticInProgress($0.value) }
        if let bestInProgress = inProgressEntries.max(by: { lhs, rhs in
            agenticPriority(lhs.value) < agenticPriority(rhs.value)
        }) {
            return mapConversationAgenticPhase(bestInProgress.value)
        }
        if let bestTerminal = orderedEntries.max(by: { lhs, rhs in
            agenticPriority(lhs.value) < agenticPriority(rhs.value)
        }) {
            return mapConversationAgenticPhase(bestTerminal.value)
        }
        return fallback
    }

    static func isAgenticInProgress(_ s: AgenticLoopState) -> Bool {
        switch s {
        case .started, .llmCall, .llmGenerationCompleted, .waitingForToolExecution, .executingTools, .betweenIterations:
            return true
        case .completed, .cancelled, .failed, .maxIterationsReached:
            return false
        }
    }

    static func mapConversationAgenticPhase(_ state: AgenticLoopState) -> ConversationAgenticPhase {
        switch state {
        case .started: return .started
        case .llmCall: return .llmCall
        case .llmGenerationCompleted: return .llmGenerationCompleted
        case .waitingForToolExecution: return .waitingForToolExecution
        case .executingTools: return .executingTools
        case .betweenIterations: return .betweenIterations
        case .completed: return .completed
        case .cancelled: return .failed
        case .failed: return .failed
        case .maxIterationsReached: return .maxIterationsReached
        }
    }

    static func pickRequestPhase(
        from states: [LLMRequestID: LLMRequestState],
        fallback: ConversationLLMRequestPhase?
    ) -> ConversationLLMRequestPhase? {
        guard !states.isEmpty else { return fallback }
        let orderedEntries = states.sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
        let inProgressEntries = orderedEntries.filter { isRequestInProgress($0.value) }
        if let bestInProgress = inProgressEntries.max(by: { lhs, rhs in
            requestPriority(lhs.value) < requestPriority(rhs.value)
        }) {
            return mapConversationRequestPhase(bestInProgress.value)
        }
        if let bestTerminal = orderedEntries.max(by: { lhs, rhs in
            requestPriority(lhs.value) < requestPriority(rhs.value)
        }) {
            return mapConversationRequestPhase(bestTerminal.value)
        }
        return fallback
    }

    static func isRequestInProgress(_ s: LLMRequestState) -> Bool {
        switch s {
        case .queued, .active, .generating, .streaming:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    static func mapConversationRequestPhase(_ state: LLMRequestState) -> ConversationLLMRequestPhase {
        switch state {
        case .queued: return .queued
        case .active: return .active
        case .generating: return .generating
        case .streaming: return .streaming
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// Same ordering as ``pickAgenticPhase(from:fallback:)`` but returns the underlying SwiftAgentKit state.
    static func pickPrimaryAgenticLoopState(from states: [AgenticLoopID: AgenticLoopState]) -> AgenticLoopState? {
        guard !states.isEmpty else { return nil }
        let orderedIDs = states.keys.sorted { stableAgenticLoopSortKey($0) < stableAgenticLoopSortKey($1) }
        for id in orderedIDs {
            if let s = states[id], isAgenticInProgress(s) {
                return s
            }
        }
        if let first = orderedIDs.first, let s = states[first] {
            return s
        }
        return nil
    }

    static func isTerminalAgentic(_ state: AgenticLoopState) -> Bool {
        switch state {
        case .completed, .cancelled, .failed, .maxIterationsReached:
            return true
        case .started, .llmCall, .llmGenerationCompleted, .waitingForToolExecution, .executingTools, .betweenIterations:
            return false
        }
    }

    static func anyLLMRequestCancelled(_ states: [LLMRequestID: LLMRequestState]) -> Bool {
        states.values.contains { if case .cancelled = $0 { return true }; return false }
    }

    static func anyLLMRequestInProgress(_ states: [LLMRequestID: LLMRequestState]) -> Bool {
        states.values.contains { isRequestInProgress($0) }
    }

    /// First `.failed` request in stable ID order; used when no request is in-flight.
    static func firstTerminalFailedLLMRequestState(from states: [LLMRequestID: LLMRequestState]) -> LLMRequestState? {
        guard !states.isEmpty else { return nil }
        let orderedIDs = states.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        for id in orderedIDs {
            if let s = states[id], case .failed = s { return s }
        }
        return nil
    }

    private static func requestPriority(_ state: LLMRequestState) -> Int {
        switch state {
        case .streaming: return 60
        case .generating: return 50
        case .active: return 40
        case .queued: return 30
        case .failed: return 20
        case .cancelled: return 10
        case .completed: return 0
        }
    }

    private static func agenticPriority(_ state: AgenticLoopState) -> Int {
        switch state {
        case .executingTools: return 70
        case .waitingForToolExecution: return 60
        case .llmGenerationCompleted: return 50
        case .llmCall: return 40
        case .betweenIterations: return 30
        case .started: return 20
        case .failed: return 10
        case .maxIterationsReached: return 8
        case .cancelled: return 6
        case .completed: return 4
        }
    }
}
