import Foundation

struct RuntimeTurnTerminalStatus: Sendable {
    let status: ConversationRunWireStatus
    let markerKind: String?
}

enum RuntimeTurnTerminalHandler {
    static let runCancelledMarkerKind = "run_cancelled"

    static func resolve(
        result: AgentRuntimeRunResult,
        conversationID: UUID,
        runID: UUID?,
        activeAnchorUserMessageID: UUID?,
        setPendingTerminalReason: @Sendable (UUID, UUID, ConversationRunTerminalReason?) async -> Void,
        stripRunTailAfterAnchorIfNeeded: @Sendable (UUID, UUID?, UUID) async -> Void,
        applyStreamingUserCancellation: @Sendable (UUID, UUID?) async -> Void,
        applySendFailure: @Sendable (Error) async -> Void,
        logInfo: @Sendable (String) async -> Void,
        logError: @Sendable (String) async -> Void
    ) async -> RuntimeTurnTerminalStatus {
        if let runID {
            await setPendingTerminalReason(conversationID, runID, result.terminalReason)
        }
        await logInfo(
            "[HarnessRuntimeSession] Runtime terminal resolve conversationID=\(conversationID.uuidString) state=\(String(describing: result.terminalState)) category=\(result.terminalReason?.category.rawValue ?? "nil") detail=\(result.terminalReason?.detail ?? "nil") boundedReason=\(result.terminalReason?.boundedReason?.rawValue ?? "nil")"
        )
        switch result.terminalState {
        case .completed:
            return RuntimeTurnTerminalStatus(status: .completed, markerKind: nil)
        case .cancelled:
            await logInfo("[HarnessRuntimeSession] Streaming orchestration task cancelled for \(conversationID)")
            if let activeAnchorUserMessageID {
                await stripRunTailAfterAnchorIfNeeded(conversationID, runID, activeAnchorUserMessageID)
            }
            await applyStreamingUserCancellation(conversationID, runID)
            return RuntimeTurnTerminalStatus(status: .cancelled, markerKind: runCancelledMarkerKind)
        case .failed:
            let classification = result.errorPolicy?.errorClass.rawValue ?? "unknown"
            let policy = result.errorPolicy?.handling.rawValue ?? "unknown"
            await logError("[HarnessRuntimeSession] Runtime turn failed (classification=\(classification), policy=\(policy))")
            if let error = result.underlyingError {
                await logError("[HarnessRuntimeSession] Runtime turn underlying error: \(error)")
            }
            if let error = result.underlyingError {
                await applySendFailure(error)
            } else {
                await applySendFailure(ConversationServiceError.failedToInitialize)
            }
            return RuntimeTurnTerminalStatus(status: .failed, markerKind: nil)
        }
    }
}
