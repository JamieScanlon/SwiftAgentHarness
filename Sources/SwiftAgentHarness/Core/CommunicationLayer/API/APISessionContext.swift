import Foundation

/// Task-local client discriminator for REST/WebSocket handlers (see ``ClientSessionMiddleware``).
enum APISessionContext {
    /// When non-nil, restricts ``apiCurrentConversationID`` / implicit send routing to this client's selection ledger row.
    /// When nil (middleware absent), ``HarnessRuntimeSession`` uses ``ClientSessionKey.implicitSharedNamespace``.
    @TaskLocal public static var connectionNamespace: UUID?

    /// Multi-tenant authenticated principal for REST/WebSocket (see ``ClientSessionMiddleware`` and WS upgrade headers).
    /// When ``TenancyPolicySettings/requireAuthenticatedOwnerOnMutations`` is enabled, mutations require this to be non-nil.
    @TaskLocal public static var authenticatedOwnerAccountID: UUID?
}
