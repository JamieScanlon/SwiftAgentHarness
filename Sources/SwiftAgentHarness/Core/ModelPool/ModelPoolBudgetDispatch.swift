//
//  enforce spend at the pool dispatch boundary.
//
//  The previous one-shot `validatePreDispatch(policy:)` was a no-op invoked once at
//  orchestrator-build time. It has been replaced by per-call `authorize(...)` /
//  `settle(...)` static facades that route through an injected ``BudgetAccounting``.
//  ``BudgetEnforcingLLM`` invokes these facades on every `send` / `stream` /
//  `generateImage`. The default ``AlwaysAllowBudgetAccounting`` keeps current behavior
//  identical; real per-call USD math + cumulative accounting follows when a non-default
//  ``BudgetAccounting`` implementation is wired.
//

import Foundation

/// Static facade over ``BudgetAccounting`` that documents the dispatch-boundary contract.
///
/// `BudgetEnforcingLLM` calls these helpers rather than the protocol directly so the
/// dispatch boundary remains a single, named seam (matches the pattern set by other
/// `ModelPool*` helpers).
enum ModelPoolBudgetDispatch {
    /// Pre-dispatch authorization. Throws ``LLMError/quotaExceeded`` (or whatever the
    /// accounting impl chose) when the call would exceed an active cap; otherwise returns.
    static func authorize(
        accounting: any BudgetAccounting,
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        try await accounting.authorize(
            policy: policy,
            modelID: modelID,
            conversationID: conversationID,
            accountID: accountID,
            projectedCostUSD: projectedCostUSD
        )
    }

    /// Post-call settlement. Always paired with a successful ``authorize(...)``; called on
    /// success, on failure-after-authorize, and on cancellation with `actualCostUSD == 0`
    /// to release any pending reservation.
    static func settle(
        accounting: any BudgetAccounting,
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        await accounting.recordCompletion(
            policy: policy,
            modelID: modelID,
            conversationID: conversationID,
            accountID: accountID,
            actualCostUSD: actualCostUSD
        )
    }
}
