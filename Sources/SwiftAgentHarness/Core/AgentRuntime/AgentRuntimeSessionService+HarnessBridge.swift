import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func runSlashCommandIfNeeded(_ text: String, conversationID: UUID) async throws -> ChatStreamResponse? {
        try await outbound.slashCommand.runSlashCommandIfNeeded(text, conversationID: conversationID)
    }

    func processControlInputBoundary(
        text: String,
        conversationID: UUID,
        configuration: Configuration
    ) async throws -> ControlInputBoundaryOutcome {
        let resolvedConfiguration = await configurationApplyingTrustPolicy(configuration)
        return try await outbound.slashCommand.processControlInputBoundary(
            text: text,
            conversationID: conversationID,
            trustClass: resolvedConfiguration.resolvedInputTrustClass,
            senderLabel: resolvedConfiguration.originSenderID
        )
    }

    func savePreTurnAcknowledgement(_ content: String, conversationID: UUID) async throws {
        let synthetic = Message(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            toolCalls: []
        )
        _ = try await messaging.saveMessageToCache(
            synthetic,
            for: conversationID,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )
        if var convo = await modelConversation(id: conversationID) {
            convo.messages.append(synthetic)
            convo.turns = await transformedTurns(
                messages: convo.messages,
                interactionMode: convo.interactionMode,
                previousTurns: convo.turns
            )
            await updateConversation(convo)
        }
    }

    func configurationApplyingTrustPolicy(_ configuration: Configuration) async -> Configuration {
        await selection.configurationApplyingTrustPolicy(configuration)
    }

    func setupOrchestrator(with model: Model, activeConversation: ModelConversation) async {
        await orchestratorPort.setupOrchestrator(with: model, activeConversation: activeConversation)
    }

    func invalidateBoundOrchestrator() async {
        await orchestratorPort.invalidateOrchestrator()
    }

    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {
        await selection.invokeTestingPreRunStateSendHook(for: conversation)
    }

    func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID
    ) async throws -> Message {
        try await messaging.saveMessageToCache(
            message,
            for: conversationID,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            transcriptRunID: transcriptRunID
        )
    }

    func updateConversation(_ conversation: ModelConversation) async {
        await messaging.update(conversation: conversation)
    }

    func transformedTurns(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn]
    ) async -> [ConversationTurn] {
        await selection.transformedTurns(
            messages: messages,
            interactionMode: interactionMode,
            previousTurns: previousTurns
        )
    }

    func touchCurrentMessagesProjection(for conversation: ModelConversation) async {
        await selection.setCurrentMessagesProjection(for: conversation)
    }

    func buildOrchestrationSnapshot(
        forStreamingConversation conversationID: UUID,
        isTerminalSnapshotAfterCompletion: Bool,
        forceStreamingPhases: Bool
    ) async -> ConversationOrchestrationState? {
        await buildOrchestrationStateSnapshotFromSwiftAgentKit(
            forStreamingConversation: conversationID,
            isTerminalSnapshotAfterCompletion: isTerminalSnapshotAfterCompletion,
            forceStreamingPhases: forceStreamingPhases
        )
    }

    func routingRevert(conversationID: UUID, userMessageID: UUID) async throws -> [Message] {
        try await deps.persistenceDomain.routingRevertConversationPreservingPrefixThroughUserMessageAsync(
            conversationID: conversationID,
            userMessageID: userMessageID
        )
    }

    func derivedCheckpointInvalidationKinds() -> [String] {
        HarnessRuntimeSession.allDerivedCheckpointInvalidationKinds
    }

    func routingAppendCheckpointInvalidation(conversationID: UUID, kinds: [String]) async throws {
        try await deps.persistenceDomain.routingAppendCheckpointInvalidationAsync(
            conversationID: conversationID,
            kinds: kinds
        )
    }

    func publishCheckpointInvalidation(conversationID: UUID, invalidatedKinds: [String]) async {
        await topics.publishCheckpointInvalidationOnTopic(
            conversationID: conversationID,
            invalidatedKinds: invalidatedKinds
        )
    }

    func syncConversationTurns(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]
    ) async {
        try? await messaging.syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    func persistSplit(
        sourceConversationID: UUID,
        atUserMessageID: UUID
    ) async throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID) {
        try await outbound.lifecycle.persistSplitSelectingNewThread(
            sourceConversationID: sourceConversationID,
            atUserMessageID: atUserMessageID,
            adoptSelection: true,
            childLineageKind: .branch
        )
    }

    func stripRunTail(conversationID: UUID, anchorUserMessageID: UUID) async {
        await messaging.stripRunTailAfterAnchorIfNeeded(
            conversationID: conversationID,
            anchorUserMessageID: anchorUserMessageID
        )
    }

    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {
        await selection.touchCurrentMessagesIfSelected(conversationID: conversationID, conversation: conversation)
    }

    func appendMessages(_ messages: [Message], conversationID: UUID) async {
        await messaging.appendMessagesToConversation(messages, conversationID: conversationID)
    }

    func refreshProjectedConversationMessages(conversationID: UUID, baseMessagesOverride: [Message]? = nil) async {
        await messaging.refreshProjectedConversationMessages(
            conversationID: conversationID,
            baseMessagesOverride: baseMessagesOverride
        )
    }

    func publishPrunedProjectionAfterRewind(
        conversation: ModelConversation,
        baseMessagesOverride: [Message]
    ) async {
        await messaging.publishPrunedProjectionAfterRewind(
            conversation: conversation,
            baseMessagesOverride: baseMessagesOverride
        )
    }

    func routingPersistRunLifecycleTranscriptMarker(
        conversationID: UUID,
        payload: RunLifecycleTranscriptMarkerPayload
    ) async throws {
        try await deps.persistenceDomain.routingPersistRunLifecycleTranscriptMarkerAsync(
            conversationID: conversationID,
            payload: payload
        )
    }

    func listRunsProjectionForAPI(
        conversationID: UUID,
        filter: ConversationRunListFilter,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?
    ) async -> ConversationRunListResponse {
        await deps.persistenceDomain.projectedRunsForAPI(
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            filter: filter
        )
    }

    func getRunProjectionForAPI(
        conversationID: UUID,
        runID: UUID,
        includeProjectionDetail: Bool,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?
    ) async -> ConversationRunInfo? {
        await deps.persistenceDomain.projectedRunForAPI(
            conversationID: conversationID,
            runID: runID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            includeProjectionDetail: includeProjectionDetail
        )
    }
}
