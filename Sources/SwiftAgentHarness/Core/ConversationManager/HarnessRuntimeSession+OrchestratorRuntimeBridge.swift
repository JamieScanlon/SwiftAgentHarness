import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension HarnessRuntimeSession {
    internal func journalEvents(
        conversationID: UUID,
        kind: String? = nil,
        journalStream: ConversationJournalStream? = nil
    ) async -> [CachedConversationEvent] {
        let (events, _) = await persistenceDomain.loadConversationEventsWithFrontier(conversationID: conversationID)
        return events.filter { event in
            if let kind, event.kind != kind { return false }
            if let journalStream, event.journalStreamRaw != journalStream.rawValue { return false }
            return true
        }
        .sorted { $0.eventID < $1.eventID }
    }

    internal func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState? {
        await agentRuntimeSessionService.snapshotOrchestrationState(for: conversationID)
    }

    @available(*, deprecated, renamed: "snapshotOrchestrationState(for:)")
    internal func snapshotTurnState() async -> ConversationOrchestrationState? {
        guard let cid = await services.conversationSelectionRuntimeService.currentConversationID else { return nil }
        return await snapshotOrchestrationState(for: cid)
    }

    internal func buildOrchestrationStateSnapshotFromSwiftAgentKit(
        forStreamingConversation streamingConversationID: UUID,
        isTerminalSnapshotAfterCompletion: Bool = false,
        forceStreamingPhases: Bool = false
    ) async -> ConversationOrchestrationState? {
        await agentRuntimeSessionService.buildOrchestrationStateSnapshotFromSwiftAgentKit(
            forStreamingConversation: streamingConversationID,
            isTerminalSnapshotAfterCompletion: isTerminalSnapshotAfterCompletion,
            forceStreamingPhases: forceStreamingPhases
        )
    }

    internal func resetContextTokenSnapshot() async {
        await agentRuntimeSessionService.resetContextTokenSnapshot()
    }

    internal func recordContextSnapshot(from response: LLMResponse, requestConfig: LLMRequestConfig) async {
        await agentRuntimeSessionService.recordContextSnapshot(from: response, requestConfig: requestConfig)
    }

    internal func emitOrchestrationStateFromLiveSources(
        swiftAgentKitGeneration: UInt64? = nil,
        preferredConversationID: UUID? = nil
    ) async {
        await agentRuntimeSessionService.emitOrchestrationStateFromLiveSources(
            swiftAgentKitGeneration: swiftAgentKitGeneration,
            preferredConversationID: preferredConversationID
        )
    }

    internal func finishOrchestrationStateStream() async {
        await agentRuntimeSessionService.finishOrchestrationStateStream()
    }

    func sessionOrchestrator() async -> SwiftAgentKitOrchestrator? {
        guard let conversationID = await services.conversationSelectionRuntimeService.currentConversationID else {
            return nil
        }
        return await agentRuntimeSessionService.orchestrator(for: conversationID)
    }

    func sessionOrchestratorConversationID() async -> UUID? {
        await services.conversationSelectionRuntimeService.currentConversationID
    }

    internal func ingestCompletionAnnouncementForAPI(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async {
        await subAgentCompletionRuntimeService.ingestCompletionAnnouncementForAPI(
            announce,
            toolMessageContent: toolMessageContent
        )
    }
}
