import Foundation
import SwiftAgentKit

enum SessionProjectionApplyOutcome: Sendable {
    case applied(shouldPublish: Bool)
    case droppedStale(projectedFrontier: Int, currentFrontier: Int)
}

protocol SessionProjectionAccessing: Sendable {
    func syncFromRegistry(conversationID: UUID, conversation: ModelConversation) async
    func replaceAllProjectedMessages(_ byConversationID: [UUID: [Message]]) async
    func applySnapshotIfNotStale(
        conversationID: UUID,
        messages: [Message],
        frontierEventID: Int,
        contentHash: Int
    ) async -> SessionProjectionApplyOutcome
    func projectedMessages(for conversation: ModelConversation) async -> [Message]
    func testing_seedProjectionPublishState(conversationID: UUID, frontierEventID: Int, contentHash: Int) async
    func testing_clearProjectionPublishState(conversationID: UUID) async
}

/// Forwards ``SessionProjectionAccessing`` calls to ``SessionProjectionRuntimeService``.
final class SessionProjectionPortAdapter: SessionProjectionAccessing, Sendable {
    /// Use of @unchecked Sendable is valid here
    private final class Backing: @unchecked Sendable {
        var projectionService: SessionProjectionRuntimeService?
        var isInstalled = false

        func install(service: SessionProjectionRuntimeService) {
            precondition(!isInstalled, "SessionProjectionRuntimeService already installed")
            projectionService = service
            isInstalled = true
        }
    }

    private let backing: Backing

    init(service: SessionProjectionRuntimeService) {
        let backing = Backing()
        backing.projectionService = service
        backing.isInstalled = true
        self.backing = backing
    }

    static func makeUnbound() -> SessionProjectionPortAdapter {
        SessionProjectionPortAdapter(backing: Backing())
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func install(service: SessionProjectionRuntimeService) {
        backing.install(service: service)
    }

    func syncFromRegistry(conversationID: UUID, conversation: ModelConversation) async {
        guard let projectionService = backing.projectionService else { return }
        await projectionService.syncFromRegistry(conversationID: conversationID, conversation: conversation)
    }

    func replaceAllProjectedMessages(_ byConversationID: [UUID: [Message]]) async {
        guard let projectionService = backing.projectionService else { return }
        await projectionService.replaceAllProjectedMessages(byConversationID)
    }

    func applySnapshotIfNotStale(
        conversationID: UUID,
        messages: [Message],
        frontierEventID: Int,
        contentHash: Int
    ) async -> SessionProjectionApplyOutcome {
        guard let projectionService = backing.projectionService else {
            return .droppedStale(projectedFrontier: frontierEventID, currentFrontier: Int.max)
        }
        return await projectionService.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: messages,
            frontierEventID: frontierEventID,
            contentHash: contentHash
        )
    }

    func projectedMessages(for conversation: ModelConversation) async -> [Message] {
        guard let projectionService = backing.projectionService else { return conversation.messages }
        return await projectionService.projectedMessages(for: conversation)
    }

    func testing_seedProjectionPublishState(conversationID: UUID, frontierEventID: Int, contentHash: Int) async {
        guard let projectionService = backing.projectionService else { return }
        await projectionService.testing_seedProjectionPublishState(
            conversationID: conversationID,
            frontierEventID: frontierEventID,
            contentHash: contentHash
        )
    }

    func testing_clearProjectionPublishState(conversationID: UUID) async {
        guard let projectionService = backing.projectionService else { return }
        await projectionService.testing_clearProjectionPublishState(conversationID: conversationID)
    }
}
