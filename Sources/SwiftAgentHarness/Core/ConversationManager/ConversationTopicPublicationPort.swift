import Foundation

public protocol ConversationTopicPublicationPort: Sendable {
    func publishCheckpointInvalidationOnTopic(conversationID: UUID, invalidatedKinds: [String]) async
    func publishContextCompactionCheckpointTopic(spec: ContextCompactionCheckpointPersistenceSpec) async
    func publishConversationTopicEventIfConfigured(
        conversationID: UUID,
        payload: ConversationTopicEventPayload
    ) async
    func publishRuntimeLifecycleEvent(_ payload: RuntimeLifecycleEventPayload) async
    func publishRuntimeLifecycleWithFanout(_ payload: RuntimeLifecycleEventPayload) async
}

/// Forwards `ConversationTopicPublicationPort` calls to runtime actors.
final class ConversationTopicPublicationPortAdapter: ConversationTopicPublicationPort, Sendable {
    /// Use of @unchecked Sendable is valid here
    private final class Backing: @unchecked Sendable {
        var topicService: ConversationTopicPublicationRuntimeService?
        var runtimeLifecyclePublication: RuntimeLifecyclePublicationService?
        var isInstalled = false

        func install(
            topicService: ConversationTopicPublicationRuntimeService,
            runtimeLifecyclePublication: RuntimeLifecyclePublicationService
        ) {
            precondition(!isInstalled, "ConversationTopicPublicationRuntimeService already installed")
            self.topicService = topicService
            self.runtimeLifecyclePublication = runtimeLifecyclePublication
            isInstalled = true
        }
    }

    private let backing: Backing

    init(
        topicService: ConversationTopicPublicationRuntimeService,
        runtimeLifecyclePublication: RuntimeLifecyclePublicationService
    ) {
        let backing = Backing()
        backing.topicService = topicService
        backing.runtimeLifecyclePublication = runtimeLifecyclePublication
        backing.isInstalled = true
        self.backing = backing
    }

    static let unbound = ConversationTopicPublicationPortAdapter.makeUnbound()

    static func makeUnbound() -> ConversationTopicPublicationPortAdapter {
        ConversationTopicPublicationPortAdapter(backing: Backing())
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func install(
        topicService: ConversationTopicPublicationRuntimeService,
        runtimeLifecyclePublication: RuntimeLifecyclePublicationService
    ) {
        backing.install(
            topicService: topicService,
            runtimeLifecyclePublication: runtimeLifecyclePublication
        )
    }

    func publishCheckpointInvalidationOnTopic(conversationID: UUID, invalidatedKinds: [String]) async {
        guard let topicService = backing.topicService else { return }
        await topicService.publishCheckpointInvalidationOnTopic(
            conversationID: conversationID,
            invalidatedKinds: invalidatedKinds
        )
    }

    func publishContextCompactionCheckpointTopic(spec: ContextCompactionCheckpointPersistenceSpec) async {
        guard let topicService = backing.topicService else { return }
        await topicService.publishContextCompactionCheckpointTopic(spec: spec)
    }

    func publishConversationTopicEventIfConfigured(
        conversationID: UUID,
        payload: ConversationTopicEventPayload
    ) async {
        guard let topicService = backing.topicService else { return }
        await topicService.publishConversationTopicEventIfConfigured(
            conversationID: conversationID,
            payload: payload
        )
    }

    func publishRuntimeLifecycleEvent(_ payload: RuntimeLifecycleEventPayload) async {
        guard let runtimeLifecyclePublication = backing.runtimeLifecyclePublication else { return }
        await runtimeLifecyclePublication.publishRuntimeLifecycleEvent(payload)
    }

    func publishRuntimeLifecycleWithFanout(_ payload: RuntimeLifecycleEventPayload) async {
        guard let runtimeLifecyclePublication = backing.runtimeLifecyclePublication else { return }
        await runtimeLifecyclePublication.publishRuntimeLifecycleWithFanout(payload)
    }
}
