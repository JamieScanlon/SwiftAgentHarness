//
//  Cross-conversation metadata and listing (harness `catalog.sqlite` responsibilities).
//
//  **Conformance:** only ``HarnessSessionPersistence`` (``SessionBackend``) should satisfy this protocol in product
//  code — a subgroup of the single README backend, not a standalone injection surface.
//

import Foundation

/// Cross-conversation metadata and listing (harness `catalog.sqlite` responsibilities).
protocol CatalogPersistence: Sendable {
    /// Full catalog listing for list/search UIs (SQLite in ``LocalHarnessSessionPersistence``; in-memory map in test backend).
    func listCatalogConversations() throws -> [SessionCatalogRecord]

    func catalogConversation(id: UUID) throws -> SessionCatalogRecord?

    /// Keyset or opaque cursor pagination (see ``SessionCatalogPage``).
    func listCatalogConversationsPage(cursor: String?, limit: Int) throws -> SessionCatalogPage
}

extension CatalogPersistence {
    func listCatalogConversationsPage(cursor: String?, limit: Int) throws -> SessionCatalogPage {
        throw SessionPersistenceError.unsupportedOperation("listCatalogConversationsPage")
    }
}
