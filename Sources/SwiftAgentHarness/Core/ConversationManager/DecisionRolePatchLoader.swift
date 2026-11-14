import Foundation
import Logging

/// Loads the mode-profile and conversation layers of role resolution for one conversation, so every `decide`
/// consumer resolves roles the same way the spec orders them.
enum DecisionRolePatchLoader {
    static func patches(
        for conversationID: UUID?,
        persistenceDomain: ConversationPersistenceDomain,
        modeRegistry: any ModeRegistryAccessing,
        logger: Logger?
    ) async -> RoleBindingPatches {
        guard let conversationID, let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            return .none
        }
        return await patches(for: conversation, modeRegistry: modeRegistry, logger: logger)
    }

    static func patches(
        for conversation: ModelConversation,
        modeRegistry: any ModeRegistryAccessing,
        logger: Logger?
    ) async -> RoleBindingPatches {
        let profile = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conversation, modeRegistry: modeRegistry, logger: logger
        )
        return RoleBindingPatches(
            mode: profile.model.roles,
            conversation: conversation.routingPrefs?.modelOptions?.roles ?? [:]
        )
    }
}
