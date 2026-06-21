import Foundation

protocol SubAgentLifecycleOrchestrationHosting: Sendable {
    func hostSpawnSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID
    func hostLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload
    func hostListActiveInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo]
    func hostCancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws
}

protocol SubAgentCompletionIngressHosting: Sendable {
    func hostPushCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async
    func hostRetryPendingAnnouncements() async
    func hostReconcileUnresolvedAnnouncementsOnStartup() async
    func hostRecoverActiveRemoteTransportsOnStartup() async
}

protocol SubAgentLifecycleOrchestrationServicing: Sendable {
    func spawnSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID
    func lifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload
    func listActiveInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo]
    func cancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws
}

protocol SubAgentCompletionIngressServicing: Sendable {
    func pushCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async
    func retryPendingAnnouncements() async
    func reconcileUnresolvedAnnouncementsOnStartup() async
    func recoverActiveRemoteTransportsOnStartup() async
}

struct SubAgentLifecycleOrchestrationService: SubAgentLifecycleOrchestrationServicing {
    private let host: any SubAgentLifecycleOrchestrationHosting

    init(host: any SubAgentLifecycleOrchestrationHosting) {
        self.host = host
    }

    func spawnSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID {
        try await host.hostSpawnSubAgent(
            parentConversationID: parentConversationID,
            request: request,
            modelOverride: modelOverride
        )
    }

    func lifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        await host.hostLifecycleSnapshot(
            conversationID: conversationID,
            pathSegments: pathSegments
        )
    }

    func listActiveInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        await host.hostListActiveInvocations(parentConversationID: parentConversationID)
    }

    func cancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        try await host.hostCancelInvocation(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        )
    }
}

struct SubAgentCompletionIngressService: SubAgentCompletionIngressServicing {
    private let host: any SubAgentCompletionIngressHosting

    init(host: any SubAgentCompletionIngressHosting) {
        self.host = host
    }

    func pushCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async {
        await host.hostPushCompletionAnnouncement(
            announce,
            toolMessageContent: toolMessageContent
        )
    }

    func retryPendingAnnouncements() async {
        await host.hostRetryPendingAnnouncements()
    }

    func reconcileUnresolvedAnnouncementsOnStartup() async {
        await host.hostReconcileUnresolvedAnnouncementsOnStartup()
    }

    func recoverActiveRemoteTransportsOnStartup() async {
        await host.hostRecoverActiveRemoteTransportsOnStartup()
    }
}
