import Foundation
import SwiftAgentKit

/// Session selection and projection mirror for harness services that cannot hold ``HarnessRuntimeSession`` directly.
///
/// Covers the L1 selection surface: active conversation, UI message projection, trust-aware turn config,
/// message-stream wiring, and lane/error helpers tied to the current selection.
/// Injected at factory time via ``HarnessRuntimeSessionFactory/makeServices(deps:persistenceDomain:)``;
/// implementations forward to ``ConversationSelectionRuntimeService`` once installed.
protocol ConversationSelectionAccessing: Sendable {
    func currentConversationID() async -> UUID?
    func currentConversation() async -> ModelConversation?
    func projectedMessages(for conversation: ModelConversation) async -> [Message]
    func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) async -> HarnessRuntimeSession.Configuration
    func transformedTurns(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn]
    ) async -> [ConversationTurn]
    func setCurrentMessagesProjection(for conversation: ModelConversation) async
    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async
    func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async
    func selectConversation(conversationID: UUID) async throws
    func reselectAfterDelete(deletedConversationID: UUID) async throws
    func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async
    func cancelMessageStreamBridge() async
    func runtimeSessionLaneKey(conversationID: UUID) async -> String
    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID?
    ) async -> ConversationServiceError
    func shouldMirrorSelectionToGlobalChatState() async -> Bool
    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async
    func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async
}

/// Forwards ``ConversationSelectionAccessing`` calls to ``ConversationSelectionRuntimeService``.
///
/// Created unbound during factory wiring so peers can depend on selection before runtime services exist.
/// ``HarnessRuntimeSessionFactory/makeServices(deps:persistenceDomain:)`` installs
/// ``ConversationSelectionRuntimeService`` before returning.
final class ConversationSelectionAccessAdapter: ConversationSelectionAccessing, Sendable {
    /// Use of @unchecked Sendable is valid here
    private final class Backing: @unchecked Sendable {
        var selectionService: ConversationSelectionRuntimeService?
        var isInstalled = false

        func install(service: ConversationSelectionRuntimeService) {
            precondition(!isInstalled, "ConversationSelectionRuntimeService already installed")
            selectionService = service
            isInstalled = true
        }
    }

    private let backing: Backing

    init(service: ConversationSelectionRuntimeService) {
        let backing = Backing()
        backing.selectionService = service
        backing.isInstalled = true
        self.backing = backing
    }

    static func makeUnbound() -> ConversationSelectionAccessAdapter {
        ConversationSelectionAccessAdapter(backing: Backing())
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func install(service: ConversationSelectionRuntimeService) {
        backing.install(service: service)
    }

    func currentConversationID() async -> UUID? {
        guard let selectionService = backing.selectionService else { return nil }
        return await selectionService.currentConversationID
    }

    func currentConversation() async -> ModelConversation? {
        guard let selectionService = backing.selectionService else { return nil }
        return await selectionService.currentConversation()
    }

    func projectedMessages(for conversation: ModelConversation) async -> [Message] {
        guard let selectionService = backing.selectionService else { return conversation.messages }
        return await selectionService.projectedMessages(for: conversation)
    }

    func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) async -> HarnessRuntimeSession.Configuration {
        guard let selectionService = backing.selectionService else { return configuration }
        return await selectionService.configurationApplyingTrustPolicy(configuration)
    }

    func transformedTurns(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn]
    ) async -> [ConversationTurn] {
        guard let selectionService = backing.selectionService else { return previousTurns }
        return await selectionService.transformedTurns(
            messages: messages,
            interactionMode: interactionMode,
            previousTurns: previousTurns
        )
    }

    func setCurrentMessagesProjection(for conversation: ModelConversation) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.setCurrentMessagesProjection(for: conversation)
    }

    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.touchCurrentMessagesIfSelected(conversationID: conversationID, conversation: conversation)
    }

    func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.setCurrentMessagesIfSelected(conversationID: conversationID, messages: messages)
    }

    func selectConversation(conversationID: UUID) async throws {
        guard let selectionService = backing.selectionService else { throw ConversationServiceError.failedToInitialize }
        try await selectionService.selectConversation(conversationID: conversationID)
    }

    func reselectAfterDelete(deletedConversationID: UUID) async throws {
        guard let selectionService = backing.selectionService else { throw ConversationServiceError.failedToInitialize }
        try await selectionService.reselectAfterDelete(deletedConversationID: deletedConversationID)
    }

    func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.wireMessageStream(continuation: continuation, initial: initial)
    }

    func cancelMessageStreamBridge() async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.cancelMessageStreamBridge()
    }

    func runtimeSessionLaneKey(conversationID: UUID) async -> String {
        guard let selectionService = backing.selectionService else {
            return "session:\(conversationID.uuidString.lowercased())"
        }
        return await selectionService.runtimeSessionLaneKey(conversationID: conversationID)
    }

    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID?
    ) async -> ConversationServiceError {
        guard let selectionService = backing.selectionService else {
            return .conversationRunInProgress(conversationID: conversationID, activeRunID: fallbackRunID)
        }
        return await selectionService.runtimeSessionError(
            for: admissionError,
            conversationID: conversationID,
            fallbackRunID: fallbackRunID,
            activeRuntimeRunIDOverride: activeRuntimeRunIDOverride
        )
    }

    func shouldMirrorSelectionToGlobalChatState() async -> Bool {
        guard let selectionService = backing.selectionService else { return false }
        return await selectionService.shouldMirrorSelectionToGlobalChatState()
    }

    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.invokeTestingPreRunStateSendHook(for: conversation)
    }

    func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async {
        guard let selectionService = backing.selectionService else { return }
        await selectionService.persistResourceBudgetHintFromContextTokens(conversationID: conversationID)
    }
}
