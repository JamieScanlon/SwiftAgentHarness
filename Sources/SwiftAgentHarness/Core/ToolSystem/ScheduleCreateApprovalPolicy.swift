import EasyJSON
import Foundation
import SwiftAgentKit

/// Argument-conditional tool approval for cross-conversation `agentTurn` schedule creates (DEF-133).
enum ScheduleCreateApprovalPolicy {
    static func requiresApproval(
        arguments: JSON,
        callerConversationID: UUID,
        parentLookup: @Sendable (UUID) async -> ModelConversation?,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool {
        guard extractString(from: arguments, key: "payloadKind") == ScheduledTaskPayloadKind.agentTurn.rawValue else {
            return false
        }
        let targetID: UUID
        if let raw = extractString(from: arguments, key: "conversationID"),
           let explicit = UUID(uuidString: raw) {
            targetID = explicit
        } else {
            return false
        }
        guard targetID != callerConversationID else { return false }
        guard let caller = await parentLookup(callerConversationID),
              let target = await parentLookup(targetID) else {
            return false
        }
        let ownerScope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations,
            authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
            callerConversation: caller,
            registryOwnerAccountID: nil
        )
        guard ToolConversationAccessPolicy.isOwnerAccessible(
            targetOwner: target.ownerAccountID,
            ownerScope: ownerScope,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        ) else {
            return false
        }
        let callerScope = caller.conversationScope()
        let callerLineageRoot = await ToolConversationAccessPolicy.lineageRoot(for: caller, parentLookup: parentLookup)
        let targetLineageRoot = await ToolConversationAccessPolicy.lineageRoot(for: target, parentLookup: parentLookup)
        return ToolConversationAccessPolicy.isLineageAccessible(
            callerScope: callerScope,
            targetConversationID: targetID,
            callerLineageRoot: callerLineageRoot,
            targetLineageRoot: targetLineageRoot
        )
    }

    private static func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }
}
