import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("SessionProjectionRuntimeService")
struct SessionProjectionRuntimeServiceTests {

    private final class RecordingSelection: ConversationSelectionAccessing, @unchecked Sendable {
        var mirroredConversationID: UUID?
        var mirroredMessages: [Message]?

        func currentConversationID() async -> UUID? { nil }
        func currentConversation() async -> ModelConversation? { nil }
        func projectedMessages(for conversation: ModelConversation) async -> [Message] { conversation.messages }
        func testing_seedProjectionPublishState(conversationID: UUID, frontierEventID: Int, contentHash: Int) async {}
        func testing_clearProjectionPublishState(conversationID: UUID) async {}
        func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) async -> HarnessRuntimeSession.Configuration { configuration }
        func transformedTurns(messages: [Message], interactionMode: InteractionMode, previousTurns: [ConversationTurn]) async -> [ConversationTurn] { previousTurns }
        func setCurrentMessagesProjection(for conversation: ModelConversation) async {}
        func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {}
        func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {
            mirroredConversationID = conversationID
            mirroredMessages = messages
        }
        func selectConversation(conversationID: UUID) async throws {}
        func reselectAfterDelete(deletedConversationID: UUID) async throws {}
        func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async {}
        func cancelMessageStreamBridge() async {}
        func runtimeSessionLaneKey(conversationID: UUID) async -> String { "session:\(conversationID.uuidString.lowercased())" }
        func runtimeSessionError(for admissionError: RuntimeLaneAdmissionError, conversationID: UUID, fallbackRunID: UUID, activeRuntimeRunIDOverride: UUID?) async -> ConversationServiceError {
            .conversationRunInProgress(conversationID: conversationID, activeRunID: fallbackRunID)
        }
        func shouldMirrorSelectionToGlobalChatState() async -> Bool { false }
        func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {}
        func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async {}
    }

    @Test("applySnapshotIfNotStale drops stale frontier and publishes on content change")
    func applySnapshotFrontierGating() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let selection = RecordingSelection()
        let service = SessionProjectionRuntimeService(persistenceDomain: domain, selection: selection)
        let conversationID = UUID()
        let messages = [Message(id: UUID(), role: .user, content: "cached", timestamp: Date())]
        let hash = ConversationEventLogService.contentHash(for: messages)

        await service.testing_seedProjectionPublishState(conversationID: conversationID, frontierEventID: 100, contentHash: hash)

        let stale = await service.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: messages,
            frontierEventID: 50,
            contentHash: hash
        )
        guard case .droppedStale(let projected, let current) = stale else {
            Issue.record("expected stale drop")
            return
        }
        #expect(projected == 50)
        #expect(current == 100)

        let changed = [Message(id: UUID(), role: .user, content: "changed", timestamp: Date())]
        let changedHash = ConversationEventLogService.contentHash(for: changed)
        let applied = await service.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: changed,
            frontierEventID: 100,
            contentHash: changedHash
        )
        guard case .applied(let shouldPublish) = applied else {
            Issue.record("expected applied outcome")
            return
        }
        #expect(shouldPublish == true)
    }

    @Test("syncFromRegistry updates cache and mirrors selection when selected")
    func syncFromRegistryMirrorsSelection() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let selection = RecordingSelection()
        let service = SessionProjectionRuntimeService(persistenceDomain: domain, selection: selection)
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let conversation = ModelConversation(model: model, messages: [], systemPrompt: "sys")
        await domain.replaceConversationInRegistry(conversation)
        selection.mirroredConversationID = conversation.id

        await service.syncFromRegistry(conversationID: conversation.id, conversation: conversation)

        let projected = await service.projectedMessages(for: conversation)
        #expect(projected.count == conversation.messages.count)
        #expect(selection.mirroredConversationID == conversation.id)
        #expect(selection.mirroredMessages?.count == conversation.messages.count)
    }
}
