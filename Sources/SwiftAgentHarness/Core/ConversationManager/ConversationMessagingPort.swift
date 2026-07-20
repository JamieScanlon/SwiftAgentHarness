import Foundation
import SwiftAgentKit

protocol ConversationMessagingPort: Sendable {
    func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) async throws -> Message
    func update(conversation: ModelConversation) async
    func appendMessagesToConversation(_ messages: [Message], conversationID: UUID) async
    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]?
    ) async throws
    func stripRunTailAfterAnchorIfNeeded(conversationID: UUID, anchorUserMessageID: UUID) async
    func refreshProjectedConversationMessages(conversationID: UUID, baseMessagesOverride: [Message]?) async
    func syncProjectionFromRegistry(conversationID: UUID) async
    /// After transcript rewind: clear publish frontier, truncate registry to prefix, publish pruned projection.
    func publishPrunedProjectionAfterRewind(
        conversation: ModelConversation,
        baseMessagesOverride: [Message]
    ) async
    func applyStreamingUserCancellation(conversationID: UUID) async
    func applySendFailure(_ error: Error, conversationID: UUID) async
    func waitUntilStreamingGenerationSettled(conversationID: UUID, runID: UUID?, timeoutMS: Int) async
    func resolveOrchestratorTargetConversationID() async -> UUID?
    func deleteConversation(conversationID: UUID) async throws
    func applyToolResultTransform(toolCall: ToolCall, result: ToolResult, conversationID: UUID?) async -> ToolResult
    func applyTurnSummaryTransformIfNeeded(conversationID: UUID) async
    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline
    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async
    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async
    func rollbackLatestAssistantTurnForRuntime(conversationID: UUID, assistantMessageID: UUID?) async
    func persistDelegateSpendSnapshot(conversationID: UUID) async
}

/// Forwards `ConversationMessagingPort` calls to a `ConversationMessagingRuntimeService` actor.
final class ConversationMessagingPortAdapter: ConversationMessagingPort, Sendable {
    /// Use of @unchecked Sendable is valid here
    private final class Backing: @unchecked Sendable {
        var messagingService: ConversationMessagingRuntimeService?
        var isInstalled = false

        func install(service: ConversationMessagingRuntimeService) {
            precondition(!isInstalled, "ConversationMessagingRuntimeService already installed")
            messagingService = service
            isInstalled = true
        }
    }

    private let backing: Backing

    init(service: ConversationMessagingRuntimeService) {
        let backing = Backing()
        backing.messagingService = service
        backing.isInstalled = true
        self.backing = backing
    }

    static let unbound = ConversationMessagingPortAdapter.makeUnbound()

    static func makeUnbound() -> ConversationMessagingPortAdapter {
        ConversationMessagingPortAdapter(backing: Backing())
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func install(service: ConversationMessagingRuntimeService) {
        backing.install(service: service)
    }

    func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) async throws -> Message {
        guard let messagingService = backing.messagingService else { throw ConversationServiceError.failedToInitialize }
        return try await messagingService.saveMessageToCache(
            message,
            for: conversationID,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            transcriptRunID: transcriptRunID
        )
    }

    func update(conversation: ModelConversation) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.update(conversation: conversation)
    }

    func appendMessagesToConversation(_ messages: [Message], conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.appendMessagesToConversation(messages, conversationID: conversationID)
    }

    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]?
    ) async throws {
        guard let messagingService = backing.messagingService else { return }
        try await messagingService.syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    func stripRunTailAfterAnchorIfNeeded(conversationID: UUID, anchorUserMessageID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.stripRunTailAfterAnchorIfNeeded(
            conversationID: conversationID,
            anchorUserMessageID: anchorUserMessageID
        )
    }

    func refreshProjectedConversationMessages(conversationID: UUID, baseMessagesOverride: [Message]?) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.refreshProjectedConversationMessages(
            conversationID: conversationID,
            baseMessagesOverride: baseMessagesOverride
        )
    }

    func syncProjectionFromRegistry(conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.syncProjectionFromRegistry(conversationID: conversationID)
    }

    func publishPrunedProjectionAfterRewind(
        conversation: ModelConversation,
        baseMessagesOverride: [Message]
    ) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.publishPrunedProjectionAfterRewind(
            conversation: conversation,
            baseMessagesOverride: baseMessagesOverride
        )
    }

    func applyStreamingUserCancellation(conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.applyStreamingUserCancellation(conversationID: conversationID)
    }

    func applySendFailure(_ error: Error, conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.applySendFailure(error, conversationID: conversationID)
    }

    func waitUntilStreamingGenerationSettled(conversationID: UUID, runID: UUID?, timeoutMS: Int) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.waitUntilStreamingGenerationSettled(
            conversationID: conversationID,
            runID: runID,
            timeoutMS: timeoutMS
        )
    }

    func resolveOrchestratorTargetConversationID() async -> UUID? {
        guard let messagingService = backing.messagingService else { return nil }
        return await messagingService.resolveOrchestratorTargetConversationID()
    }

    func deleteConversation(conversationID: UUID) async throws {
        guard let messagingService = backing.messagingService else { throw ConversationServiceError.failedToInitialize }
        try await messagingService.deleteConversation(conversationID: conversationID)
    }

    func applyToolResultTransform(toolCall: ToolCall, result: ToolResult, conversationID: UUID? = nil) async -> ToolResult {
        guard let messagingService = backing.messagingService else { return result }
        return await messagingService.applyToolResultTransform(toolCall: toolCall, result: result, conversationID: conversationID)
    }

    func applyTurnSummaryTransformIfNeeded(conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.applyTurnSummaryTransformIfNeeded(conversationID: conversationID)
    }

    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline {
        guard let messagingService = backing.messagingService else { return ToolResultMiddlewarePipeline(registrations: []) }
        return await messagingService.runtimeToolResultMiddlewarePipeline()
    }

    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.installTurnToolRegistryEntries(entries)
    }

    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.registerAgentToolResultMiddleware(middleware)
    }

    func rollbackLatestAssistantTurnForRuntime(conversationID: UUID, assistantMessageID: UUID?) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.rollbackLatestAssistantTurnForRuntime(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID
        )
    }

    func persistDelegateSpendSnapshot(conversationID: UUID) async {
        guard let messagingService = backing.messagingService else { return }
        await messagingService.persistDelegateSpendSnapshot(conversationID: conversationID)
    }
}
