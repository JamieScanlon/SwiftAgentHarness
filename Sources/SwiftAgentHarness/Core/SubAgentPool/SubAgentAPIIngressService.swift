import Foundation

/// API ingress for sub-agent lifecycle and completion (replaces session-backed host adapter).
public struct SubAgentAPIIngressService: SubAgentLifecycleOrchestrationHosting, SubAgentCompletionIngressHosting {
    public let spawn: SubAgentSpawnService
    public let completion: SubAgentCompletionRuntimeService

    public init(spawn: SubAgentSpawnService, completion: SubAgentCompletionRuntimeService) {
        self.spawn = spawn
        self.completion = completion
    }

    public func hostSpawnSubAgent(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?
    ) async throws -> UUID {
        try await spawn.spawnSubAgentViaPool(
            parentConversationID: parentConversationID,
            request: request,
            modelOverride: modelOverride
        )
    }

    public func hostLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        await spawn.lifecycleSnapshot(conversationID: conversationID, pathSegments: pathSegments)
    }

    public func hostListActiveInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        await spawn.listActiveInvocations(parentConversationID: parentConversationID)
    }

    public func hostCancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        try await spawn.cancelInvocation(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        )
    }

    public func hostPushCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async {
        await completion.ingestCompletionAnnouncementForAPI(
            announce,
            toolMessageContent: toolMessageContent
        )
    }

    public func hostRetryPendingAnnouncements() async {
        await completion.retryPendingCompletionAnnouncements()
    }

    public func hostReconcileUnresolvedAnnouncementsOnStartup() async {
        await completion.reconcileUnresolvedCompletionAnnouncementsOnStartup()
    }

    public func hostRecoverActiveRemoteTransportsOnStartup() async {
        await spawn.recoverActiveRemoteSubAgentTransportsOnStartup()
        await spawn.publishOrphanedSubAgentNotificationsAfterStartup()
    }
}
