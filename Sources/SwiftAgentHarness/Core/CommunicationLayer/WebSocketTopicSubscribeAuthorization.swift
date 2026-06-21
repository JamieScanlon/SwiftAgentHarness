import Foundation

/// Subscribe-time gates for multiplexed harness topics.
enum WebSocketTopicSubscribeAuthorization {
    /// Stable client-visible denial for gated topics.
    static let deniedMessage = "Subscribe denied"

    /// Pure tenancy / existence check for reuse in tests.
    static func deniedReason(conversation: ModelConversation?, registryScope: UUID?) -> String? {
        guard let conversation else {
            return deniedMessage
        }
        if let scope = registryScope {
            guard conversation.ownerAccountID == scope else {
                return deniedMessage
            }
        }
        return nil
    }

    static func deniedReasonForConversationObservation(
        conversationID: UUID,
        session: APILayerConversationManaging
    ) async -> String? {
        let conv = await session.apiGetConversation(id: conversationID)
        let scope = await session.apiRegistryOwnerAccountID()
        return deniedReason(conversation: conv, registryScope: scope)
    }

    static func deniedReasonForModelStateSubscribe(
        modelID: UUID,
        modelManager: APILayerModelManaging
    ) async -> String? {
        let models = await modelManager.getAvailableModels()
        guard models.contains(where: { $0.id == modelID }) else {
            return deniedMessage
        }
        return nil
    }

    static func deniedReasonForServerTraceSubscribe(
        authenticatedOwnerAccountID: UUID?,
        policy: ServerTraceSubscribePolicy
    ) -> String? {
        deniedReasonForOperatorScopedSubscribe(
            authenticatedOwnerAccountID: authenticatedOwnerAccountID,
            policy: policy
        )
    }

    static func deniedReasonForOperatorScopedSubscribe(
        authenticatedOwnerAccountID: UUID?,
        policy: ServerTraceSubscribePolicy
    ) -> String? {
        guard policy.enforceOperatorAllowlist else { return nil }
        guard let owner = authenticatedOwnerAccountID else { return deniedMessage }
        guard policy.operatorOwnerIDs.contains(owner) else { return deniedMessage }
        return nil
    }
}
