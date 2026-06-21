import Foundation

/// Subscribe-time policy for operator-scoped observability topics (`trace/server`, `pool/health`).
public struct ServerTraceSubscribePolicy: Sendable, Equatable {
    public var enforceOperatorAllowlist: Bool
    public var operatorOwnerIDs: Set<UUID>

    public init(enforceOperatorAllowlist: Bool, operatorOwnerIDs: Set<UUID>) {
        self.enforceOperatorAllowlist = enforceOperatorAllowlist
        self.operatorOwnerIDs = operatorOwnerIDs
    }

    public static let open = ServerTraceSubscribePolicy(enforceOperatorAllowlist: false, operatorOwnerIDs: [])

    /// Returns a startup-blocking issue when enforcement is active but misconfigured.
    /// An empty allowlist is valid: subscribe is denied for all clients until operators are configured.
    public func validationIssue() -> String? {
        nil
    }
}
