import EasyJSON
import Foundation
import SwiftAgentKit

/// Conversation transcript replay (sandbox lifecycle, transform hooks, finalize).
public actor ConversationReplayService {
    typealias Configuration = HarnessRuntimeSession.Configuration

    private let replayProcessingDebugModeEnabled = true
    private var replayTasksByConversationID: [UUID: Task<Void, Never>] = [:]
    private var replayStopRequestedConversationIDs: Set<UUID> = []
    private var replaySourceConversationID: UUID?
    private var replaySandboxConversationID: UUID?

    private let deps: ConversationRuntimeDependencies
    private let contextProjection: ContextProjectionService
    private let selection: ConversationSelectionAccessing
    private let sessionProjection: SessionProjectionAccessing
    private let messaging: ConversationMessagingPort

    init(
        deps: ConversationRuntimeDependencies,
        contextProjection: ContextProjectionService,
        selection: ConversationSelectionAccessing,
        sessionProjection: SessionProjectionAccessing,
        messaging: ConversationMessagingPort
    ) {
        self.deps = deps
        self.contextProjection = contextProjection
        self.selection = selection
        self.sessionProjection = sessionProjection
        self.messaging = messaging
    }


    func isConversationReplayActive(conversationID: UUID) async -> Bool {
        if let sand = replaySandboxConversationID,
           let src = replaySourceConversationID,
           conversationID == src || conversationID == sand {
            return replayTasksByConversationID[sand] != nil
        }
        return replayTasksByConversationID[conversationID] != nil
    }

    func stopConversationReplay(conversationID: UUID) async {
        let sandboxID = resolveReplaySandboxID(for: conversationID)
        replayStopRequestedConversationIDs.insert(sandboxID)
        guard let task = replayTasksByConversationID.removeValue(forKey: sandboxID) else {
            return
        }
        task.cancel()
        await task.value
    }

    func cancelAllActiveTasks() async {
        let tasks = Array(replayTasksByConversationID.values)
        replayTasksByConversationID.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.result
        }
    }

    internal func testing_hasActiveReplayTasks() -> Bool {
        !replayTasksByConversationID.isEmpty
    }

    func serviceRuntimeStartConversationReplay(
        sourceConversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws {
        try await startConversationReplay(
            sourceConversationID: sourceConversationID,
            configuration: Configuration(runtimeConfiguration: configuration)
        )
    }

    func startConversationReplay(sourceConversationID: UUID, configuration: Configuration = .init()) async throws {
        let logger = deps.logger
        guard replayProcessingDebugModeEnabled else {
            logger?.warning("[ConversationReplayService] Replay processing is disabled by debug gate")
            return
        }
        guard replayTasksByConversationID.isEmpty else {
            throw ConversationServiceError.conversationReplayAlreadyRunning
        }
        guard let sourceConversation = await deps.persistenceDomain.modelConversation(id: sourceConversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let sourceID = sourceConversation.id
        let transcript = await selection.projectedMessages(for: sourceConversation)
        let replaySourceMessages = transcript.filter { $0.role != .system }
        let replayLLM = ReplayLLM(
            messageBatches: ConversationReplayRunner.messageBatches(from: replaySourceMessages)
        )
        let sysPrompt = sourceConversation.messages.first(where: { $0.role == .system })?.content ?? ""
        let sandboxID = try await createConversationForReplay(
            with: sourceConversation.model,
            userSystemPrompt: sysPrompt,
            topic: sourceConversation.topic,
            description: sourceConversation.description,
            metadata: sourceConversation.metadata,
            interactionMode: sourceConversation.interactionMode
        )
        guard sandboxID != sourceID else {
            throw ConversationServiceError.failedToInitialize
        }
        replaySourceConversationID = sourceID
        replaySandboxConversationID = sandboxID
        replayStopRequestedConversationIDs.remove(sandboxID)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConversationReplay(
                conversationID: sandboxID,
                replayLLM: replayLLM,
                configuration: configuration
            )
            await self.finalizeReplaySandbox(sandboxID: sandboxID, restoreTo: sourceID)
        }
        replayTasksByConversationID[sandboxID] = task
    }

    private func createConversationForReplay(
        with model: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode
    ) async throws -> UUID {
        let newConversation = try await deps.persistenceDomain.createConversation(
            with: model,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            ownerAccountID: APISessionContext.authenticatedOwnerAccountID
        )
        try await persistNewConversationJournalAndProjection(newConversation)
        return newConversation.id
    }

    private func persistNewConversationJournalAndProjection(_ newConversation: ModelConversation) async throws {
        let conversationID = newConversation.id
        let journalMessages = try await deps.persistenceDomain.messagesNeedingTranscriptMessageAppendedJournal(
            conversationID: conversationID,
            messages: newConversation.messages
        )
        if !journalMessages.isEmpty {
            try await deps.persistenceDomain.routingAppendMessageJournalEntriesAsync(
                conversationID: conversationID,
                messages: journalMessages
            )
        }
        await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: newConversation)
    }

    private func runConversationReplay(
        conversationID: UUID,
        replayLLM: ReplayLLM,
        configuration: Configuration
    ) async {
        defer {
            replayStopRequestedConversationIDs.remove(conversationID)
        }

        var replayedMessages: [Message] = []
        while !Task.isCancelled, !replayStopRequestedConversationIDs.contains(conversationID) {
            guard let batch = await replayLLM.nextMessageBatch(), !batch.isEmpty else {
                break
            }
            for sourceMessage in batch {
                if Task.isCancelled || replayStopRequestedConversationIDs.contains(conversationID) {
                    break
                }
                guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
                    return
                }

                _ = await contextProjection.transformedContextMessages(
                    from: conversation.messages + [sourceMessage],
                    conversation: conversation,
                    phase: .initial,
                    configuration: configuration,
                    gatingOverride: nil
                )

                var processedMessage = sourceMessage
                if processedMessage.role == .tool, configuration.enableTools {
                    let toolCall = ConversationReplayRunner.toolCall(for: processedMessage, replayedMessages: replayedMessages)
                    let rawResult = ToolResult(
                        success: true,
                        content: processedMessage.content,
                        metadata: .object([:]),
                        toolCallId: processedMessage.toolCallId
                    )
                    let transformedResult = await messaging.applyToolResultTransform(
                        toolCall: toolCall,
                        result: rawResult,
                        conversationID: conversationID
                    )
                    processedMessage = Message(
                        id: processedMessage.id,
                        role: processedMessage.role,
                        content: transformedResult.content,
                        timestamp: processedMessage.timestamp,
                        images: processedMessage.images,
                        toolCalls: processedMessage.toolCalls,
                        toolCallId: processedMessage.toolCallId,
                        responseFormat: processedMessage.responseFormat
                    )
                }

                await messaging.appendMessagesToConversation([processedMessage], conversationID: conversationID)
                replayedMessages.append(processedMessage)

                let nextBatch = await replayLLM.peekNextMessageBatch()
                let nextMessage = nextBatch?.first
                let shouldFinalizeTurn = processedMessage.role == .assistant
                    && (nextMessage == nil || nextMessage?.role == .user)
                if shouldFinalizeTurn {
                    await messaging.applyTurnSummaryTransformIfNeeded(conversationID: conversationID)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func finalizeReplaySandbox(sandboxID: UUID, restoreTo sourceID: UUID) async {
        let logger = deps.logger
        replayStopRequestedConversationIDs.remove(sandboxID)
        replaySourceConversationID = nil
        replaySandboxConversationID = nil
        do {
            try await messaging.deleteConversation(conversationID: sandboxID)
        } catch {
            logger?.warning("[ConversationReplayService] Failed to delete replay sandbox \(sandboxID): \(error)")
        }
        do {
            try await selection.selectConversation(conversationID: sourceID)
            if let source = await deps.persistenceDomain.modelConversation(id: sourceID) {
                await messaging.refreshProjectedConversationMessages(
                    conversationID: sourceID,
                    baseMessagesOverride: nil
                )
                await selection.touchCurrentMessagesIfSelected(conversationID: sourceID, conversation: source)
            }
        } catch {
            logger?.warning("[ConversationReplayService] Failed to restore selection after replay: \(error)")
        }
        replayTasksByConversationID.removeValue(forKey: sandboxID)
    }

    private func resolveReplaySandboxID(for conversationID: UUID) -> UUID {
        if let sand = replaySandboxConversationID,
           let src = replaySourceConversationID,
           conversationID == src {
            return sand
        }
        return conversationID
    }
}
