//
//  Catalog-independent conversation-id recovery discovery (Gap 12).
//

import Foundation

enum SessionRecoveryDiscoveryService {
    static func discoverRecoverableConversationIds(root: URL, agentId: String) -> [UUID] {
        SessionPersistenceLiteRecovery.discoverConversationIds(root: root, agentId: agentId)
    }
}
