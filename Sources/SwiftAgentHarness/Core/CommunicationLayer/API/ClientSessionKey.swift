//
//  Identifies a client scope for per-connection conversation selection (multi-tab / multi-client).
//

import Foundation

/// Stable scope for ``ConversationSelectionLedger`` entries.
///
/// - **tenantScope:** Mirrors ``HarnessRuntimeSession/registryOwnerAccountScope`` when catalog isolation is enabled (`nil` when single-tenant).
/// - **connectionNamespace:** Per-tab / per-WebSocket-connection discriminator.
///
/// When REST middleware omits a client header/cookie, ``APISessionContext`` leaves ``connectionNamespace`` unset and
/// ``HarnessRuntimeSession`` uses ``implicitSharedNamespace`` for deterministic anonymous-session scoping.
struct ClientSessionKey: Hashable, Sendable {
    var tenantScope: UUID?
    var connectionNamespace: UUID

    /// Shared namespace for anonymous REST calls without ``X-SAH-Client-Session`` / cookie (tests + single-client CLI).
    static let implicitSharedNamespace = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
}
