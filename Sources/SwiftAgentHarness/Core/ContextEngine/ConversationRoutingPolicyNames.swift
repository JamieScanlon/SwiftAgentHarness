import Foundation

enum ConversationRoutingPolicyNames {
    static func names(for conversation: ModelConversation) -> (tools: [String], skills: [String]) {
        guard let policy = conversation.routingPrefs?.explicitToolPolicy else {
            return ([], [])
        }
        switch policy {
        case .allowlist(let tools, let skills), .denylist(let tools, let skills):
            return (tools.sorted(), skills.sorted())
        }
    }
}
