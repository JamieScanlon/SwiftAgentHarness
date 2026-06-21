import Foundation

public enum ConversationCatalogVisibilityFilter: String, Codable, Sendable, CaseIterable {
    case primaryOnly
    case automationsOnly
    /// User-facing catalog rows (primary + automations); excludes sub-agent threads.
    case catalogVisible
    case allIncludingHidden
}
