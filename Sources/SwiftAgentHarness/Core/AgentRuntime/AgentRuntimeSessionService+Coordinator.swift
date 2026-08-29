import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService: AgentRuntimeCoordinatorServicing {
    func afterTurnContextEngineLifecycle(
        conversationID: UUID,
        runID: UUID?,
        terminalReason: ConversationRunTerminalReason?,
        anchorUserMessageID: UUID?
    ) async {
        let recentMessages: [Message]
        if let conversation = await modelConversation(id: conversationID) {
            recentMessages = conversation.messages
        } else {
            recentMessages = []
        }
        _ = await deps.contextEngine.afterTurn(
            request: ContextEngineAfterTurnRequest(
                conversationID: conversationID,
                runID: runID,
                terminalReason: terminalReason,
                anchorUserMessageID: anchorUserMessageID,
                recentMessages: recentMessages
            )
        )
        // No-op unless this conversation is a spawned sub-agent child; when it is, the run just
        // ended, so its run-lane slot is released here rather than waiting for whoever spawned it
        // to write a terminal lifecycle row.
        await subAgentSpawnServiceForRuntime()?.finishSubAgentLifecycleForEndedChildRun(
            childConversationID: conversationID,
            terminalReason: terminalReason
        )
    }

    func makeTerminationRecoveryReminderMessage(
        conversationID: UUID,
        attempt: Int,
        reminder: ModeProfileTerminationRecoveryReminder
    ) async -> Message? {
        guard reminder != .off else { return nil }
        deps.logger?.info(
            "[AgentRuntimeSessionService] creating termination recovery reminder conversationID=\(conversationID.uuidString) attempt=\(attempt) reminder=\(reminder.rawValue)"
        )
        switch reminder {
        case .off:
            return nil
        case .escalating:
            return Message(
                id: UUID(),
                role: .system,
                content: """
                [Ephemeral runtime notice] A tool call is required for this turn.
                Attempt \(attempt). Call an allowed tool now. Use a terminal tool call when work is complete.
                """,
                timestamp: Date(),
                toolCalls: []
            )
        }
    }
}
