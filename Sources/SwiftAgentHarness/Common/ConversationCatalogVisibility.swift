import Foundation

public enum ConversationCatalogVisibility {
    public static func isPrimaryCatalog(lineage: ConversationLineageKind, origin: ConversationOrigin) -> Bool {
        origin == .user && (lineage == .root || lineage == .branch)
    }

    public static func isAutomationsCatalog(lineage: ConversationLineageKind, origin: ConversationOrigin) -> Bool {
        origin == .system && lineage == .root
    }

    public static func isHiddenFromCatalog(lineage: ConversationLineageKind) -> Bool {
        lineage == .subAgent
    }

    public static func catalogSection(lineage: ConversationLineageKind, origin: ConversationOrigin) -> ConversationCatalogSection? {
        if isHiddenFromCatalog(lineage: lineage) { return nil }
        if isPrimaryCatalog(lineage: lineage, origin: origin) { return .primary }
        if isAutomationsCatalog(lineage: lineage, origin: origin) { return .automations }
        return nil
    }

    public static func matchesFilter(
        lineage: ConversationLineageKind,
        origin: ConversationOrigin,
        filter: ConversationCatalogVisibilityFilter
    ) -> Bool {
        switch filter {
        case .primaryOnly:
            return isPrimaryCatalog(lineage: lineage, origin: origin)
        case .automationsOnly:
            return isAutomationsCatalog(lineage: lineage, origin: origin)
        case .catalogVisible:
            return !isHiddenFromCatalog(lineage: lineage)
        case .allIncludingHidden:
            return true
        }
    }
}
