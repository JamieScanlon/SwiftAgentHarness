import Foundation

/// API ingress for sub-agent lifecycle and completion (replaces session-backed host adapter).
struct SubAgentAPIIngressService: SubAgentLifecycleOrchestrationHosting, SubAgentCompletionIngressHosting {
    let spawn: SubAgentSpawnService
    let completion: SubAgentCompletionRuntimeService

    func hostSpawnSubAgent(
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

    func hostLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        await spawn.lifecycleSnapshot(conversationID: conversationID, pathSegments: pathSegments)
    }

    func hostListActiveInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        await spawn.listActiveInvocations(parentConversationID: parentConversationID)
    }

    func hostCancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        try await spawn.cancelInvocation(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        )
    }

    func hostPushCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async {
        await completion.ingestCompletionAnnouncementForAPI(
            announce,
            toolMessageContent: toolMessageContent
        )
    }

    func hostRetryPendingAnnouncements() async {
        await completion.retryPendingCompletionAnnouncements()
    }

    func hostReconcileUnresolvedAnnouncementsOnStartup() async {
        await completion.reconcileUnresolvedCompletionAnnouncementsOnStartup()
    }

    func hostRecoverActiveRemoteTransportsOnStartup() async {
        await spawn.recoverActiveRemoteSubAgentTransportsOnStartup()
        await spawn.publishOrphanedSubAgentNotificationsAfterStartup()
    }
}
