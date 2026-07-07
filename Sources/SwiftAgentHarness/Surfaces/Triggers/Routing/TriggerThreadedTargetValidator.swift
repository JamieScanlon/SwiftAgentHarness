import Foundation
import SwiftAgentKit

/// Defense-in-depth validation for threaded trigger routing to explicit conversation IDs (DEF-133).
enum TriggerThreadedTargetValidator {
    static func validate(
        conversationID: UUID,
        trigger: HarnessTrigger,
        catalog: any ConversationCatalogServicing,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool {
        guard let stampedOwnerRaw = trigger.sourceMetadata["ownerAccountID"],
              let stampedOwner = UUID(uuidString: stampedOwnerRaw) else {
            if trigger.source == .cron {
                return false
            }
            return true
        }
        guard let conversation = await catalog.getConversation(id: conversationID) else {
            return false
        }
        if tenancyPolicy.requireAuthenticatedOwnerOnMutations {
            return conversation.ownerAccountID == stampedOwner
        }
        guard let conversationOwner = conversation.ownerAccountID else {
            return true
        }
        return conversationOwner == stampedOwner
    }
}
