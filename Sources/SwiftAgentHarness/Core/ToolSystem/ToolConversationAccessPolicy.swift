import EasyJSON
import Foundation

/// Owner and lineage-tree access rules for model-invoked conversation tools (DEF-126 / SEC-011 tool layer).
enum ToolConversationAccessPolicy {
    /// Resolves the effective tenant scope for tool data access.
    static func resolveOwnerScope(
        authenticatedOwnerAccountID: UUID?,
        callerConversation: ModelConversation?,
        registryOwnerAccountID: UUID?
    ) -> UUID? {
        authenticatedOwnerAccountID
            ?? callerConversation?.ownerAccountID
            ?? registryOwnerAccountID
    }

    static func isOwnerAccessible(targetOwner: UUID?, ownerScope: UUID?) -> Bool {
        guard let ownerScope else { return true }
        return targetOwner == ownerScope
    }

    /// Walks parent links (and sub-agent metadata root) to the lineage root conversation id.
    static func lineageRoot(
        for conversation: ModelConversation,
        parentLookup: (UUID) -> ModelConversation?
    ) -> UUID {
        if let metadataRoot = subAgentRootConversationID(from: conversation.metadata) {
            return metadataRoot
        }
        var current = conversation
        while let parentID = current.parentConversationID,
              let parent = parentLookup(parentID) {
            current = parent
        }
        return current.id
    }

    static func lineageRoot(
        for conversation: ModelConversation,
        parentLookup: @Sendable (UUID) async -> ModelConversation?
    ) async -> UUID {
        if let metadataRoot = subAgentRootConversationID(from: conversation.metadata) {
            return metadataRoot
        }
        var current = conversation
        while let parentID = current.parentConversationID,
              let parent = await parentLookup(parentID) {
            current = parent
        }
        return current.id
    }

    static func lineageRoot(
        for metadata: ConversationMetadata,
        metadataByID: [UUID: ConversationMetadata]
    ) -> UUID {
        guard let conversationID = UUID(uuidString: metadata.id) else {
            return UUID()
        }
        var current = metadata
        var currentID = conversationID
        var visited: Set<UUID> = [currentID]
        while let parentID = current.parentConversationID,
              metadataByID[parentID] != nil,
              !visited.contains(parentID) {
            visited.insert(parentID)
            currentID = parentID
            current = metadataByID[parentID]!
        }
        return currentID
    }

    static func isLineageAccessible(
        callerScope: ConversationScope?,
        targetConversationID: UUID,
        callerLineageRoot: UUID,
        targetLineageRoot: UUID
    ) -> Bool {
        guard let callerScope else { return true }
        if targetConversationID == callerScope.selfID { return true }
        return callerLineageRoot == targetLineageRoot
    }

    static func isConversationAccessible(
        target: ModelConversation,
        callerScope: ConversationScope?,
        ownerScope: UUID?,
        callerLineageRoot: UUID?,
        targetLineageRoot: UUID?
    ) -> Bool {
        guard isOwnerAccessible(targetOwner: target.ownerAccountID, ownerScope: ownerScope) else {
            return false
        }
        guard let callerScope else { return true }
        guard let callerLineageRoot, let targetLineageRoot else { return false }
        return isLineageAccessible(
            callerScope: callerScope,
            targetConversationID: target.id,
            callerLineageRoot: callerLineageRoot,
            targetLineageRoot: targetLineageRoot
        )
    }

    static func filterAccessibleMetadata(
        _ rows: [ConversationMetadata],
        callerScope: ConversationScope?,
        ownerScope: UUID?,
        callerLineageRoot: UUID?
    ) -> [ConversationMetadata] {
        let metadataByID: [UUID: ConversationMetadata] = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = UUID(uuidString: row.id) else { return nil }
                return (id, row)
            }
        )
        return rows.filter { row in
            guard let rowID = UUID(uuidString: row.id) else { return false }
            guard isOwnerAccessible(targetOwner: row.ownerAccountID, ownerScope: ownerScope) else {
                return false
            }
            guard let callerScope else { return true }
            guard let callerLineageRoot else { return false }
            let targetRoot = lineageRoot(for: row, metadataByID: metadataByID)
            return isLineageAccessible(
                callerScope: callerScope,
                targetConversationID: rowID,
                callerLineageRoot: callerLineageRoot,
                targetLineageRoot: targetRoot
            )
        }
    }

    private static func subAgentRootConversationID(from metadata: JSON?) -> UUID? {
        guard case .object(let object) = metadata,
              let raw = object["subAgentRootConversationID"]?.literalValue as? String,
              let uuid = UUID(uuidString: raw) else {
            return nil
        }
        return uuid
    }
}
