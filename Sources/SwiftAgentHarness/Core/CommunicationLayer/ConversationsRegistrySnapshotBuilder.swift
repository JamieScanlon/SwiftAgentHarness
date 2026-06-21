import Foundation

/// Builds account/session conversation catalog payloads for `conversations/registry`.
enum ConversationsRegistrySnapshotBuilder {
    static func snapshot(conversation: APILayerConversationManaging, accountID: String? = nil) async -> ConversationsRegistryPayload {
        let scope = await conversation.apiRegistryOwnerAccountID()
        let metadataRows = await conversation.apiListConversationMetadata(visibility: .catalogVisible)
        let filtered = metadataRows.filter { row in
            guard let scope else { return true }
            return row.ownerAccountID == scope
        }
        let changes: [ConversationRegistryChange] = filtered.compactMap { row in
            guard let conversationID = UUID(uuidString: row.id) else { return nil }
            return ConversationRegistryChange(kind: .added, conversationID: conversationID, metadata: row)
        }
        return ConversationsRegistryPayload(accountID: accountID, changes: changes, updatedAt: Date())
    }

    static func event(
        kind: ConversationRegistryChange.Kind,
        conversationID: UUID,
        conversation: APILayerConversationManaging,
        accountID: String? = nil
    ) async -> ConversationsRegistryPayload {
        let scope = await conversation.apiRegistryOwnerAccountID()
        let rows = await conversation.apiListConversationMetadata(visibility: .catalogVisible)
        let metadata = rows.first { $0.id == conversationID.uuidString }
        if metadata == nil, kind == .added {
            return ConversationsRegistryPayload(accountID: accountID, changes: [], updatedAt: Date())
        }
        if let scope, let meta = metadata, meta.ownerAccountID != scope {
            return ConversationsRegistryPayload(accountID: accountID, changes: [], updatedAt: Date())
        }
        return ConversationsRegistryPayload(
            accountID: accountID,
            changes: [ConversationRegistryChange(kind: kind, conversationID: conversationID, metadata: metadata)],
            updatedAt: Date()
        )
    }
}
