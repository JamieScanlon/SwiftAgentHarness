import Foundation

/// Optional adapter auth probe seam for provider-profile bindings.
///
/// Return semantics:
/// - `false`: credentials are definitively invalid for this binding/profile (for example 401/403).
/// - `true`: credentials appear valid, or validity cannot be determined confidently.
///
/// Adapters that cannot run a provider-specific probe should return `true` (conservative allow)
/// to avoid incorrectly suppressing a binding due to transient transport failures.
public protocol AdapterAuthProbing: Sendable {
    func validateAuth() async -> Bool
}

