import Foundation

/// Per-call dispatch-boundary decision surface.
///
/// `BudgetEnforcingLLM` and ``ModelPoolBudgetDispatch`` call into this protocol once per
/// logical call (before the request reaches the inner adapter, and again after it
/// terminates). Implementations decide whether the call is allowed under the active
/// ``BudgetPolicy`` and record completion for any cumulative accounting they maintain.
///
/// The default implementation, ``AlwaysAllowBudgetAccounting``, no-ops on both methods so
/// the existing pipeline behaves identically when no real accounting has been wired up.
/// Real per-call USD projection, per-conversation/per-account accumulators, and wire publishing of
/// `budgetRemaining` / `projectedCostUSD` follow when a non-default ``BudgetAccounting``
/// implementation is wired.
public protocol BudgetAccounting: Sendable {
    /// Decide whether a per-call dispatch is allowed under the active `policy`.
    /// Throw on cap-exceeded; callers will surface this to consumers as
    /// ``LLMError/quotaExceeded``.
    ///
    /// - Parameters:
    ///   - policy: Active ``BudgetPolicy`` (`.disabled` or `.enabled(...)`).
    ///   - modelID: Resolved ``Model/id`` for the call.
    ///   - conversationID: Owning conversation (`nil` for one-off calls outside a chat).
    ///   - accountID: Owning account when known; used for account-scope policy caps.
    ///   - projectedCostUSD: Best-effort pre-call USD estimate. `nil` until the Net-new
    ///     projection slice lands; implementations may combine this with account/global policy limits.
    func authorize(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws

    /// Settle the call after it terminates.
    ///
    /// `actualCostUSD == nil` means "unknown / failure / pre-accounting" — implementations
    /// may treat that as zero spend or skip the increment. This wrapper invokes
    /// `recordCompletion` on success and on failure-after-authorize; cancellation
    /// settles with `actualCostUSD == 0` so implementations can release reservations.
    func recordCompletion(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async
}

/// Default ``BudgetAccounting`` for tests and explicit opt-out. Production uses ``ModelPoolCostLedger``.
public struct AlwaysAllowBudgetAccounting: BudgetAccounting {
    public init() {}

    public func authorize(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        let _ = (policy, modelID, conversationID, accountID, projectedCostUSD)
    }

    public func recordCompletion(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        let _ = (policy, modelID, conversationID, accountID, actualCostUSD)
    }
}
