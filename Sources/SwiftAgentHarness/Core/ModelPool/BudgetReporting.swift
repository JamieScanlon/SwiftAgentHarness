import Foundation

/// Read-only seam used by the communication layer to surface budget signals on existing
/// topic payloads (`pool/health.budgetRemaining`, `conversation/{id}/state.projectedCostUSD`).
///
/// The default ``NilBudgetReporting`` returns `nil` from both methods.Plumbing the protocol now 
/// lets clients begin observing the fields without
/// a breaking schema change later.
public protocol BudgetReporting: Sendable {
    /// Pool-wide remaining USD budget. `nil` when not tracked or when no policy is active.
    func poolBudgetRemainingUSD() async -> Double?

    /// Projected USD spend for the given conversation. `nil` when not tracked or unknown.
    func projectedCostUSD(conversationID: UUID) async -> Double?
}

/// No-op default ``BudgetReporting`` used while the cost catalog and cumulative
/// `BudgetAccounting` are not yet implemented. Always returns `nil`.
public struct NilBudgetReporting: BudgetReporting {
    public init() {}

    public func poolBudgetRemainingUSD() async -> Double? { nil }

    public func projectedCostUSD(conversationID: UUID) async -> Double? { nil }
}
