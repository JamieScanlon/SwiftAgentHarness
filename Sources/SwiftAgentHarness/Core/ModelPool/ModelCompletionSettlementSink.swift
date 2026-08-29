import Foundation
import Synchronization

/// Carries the *settled* USD for a model call from the budget gate back to the turn loop.
///
/// `BudgetEnforcingLLM` is the only place that knows what a completion actually cost: it is
/// constructed per dispatched model and holds that model's `ModelCostBudget`. The turn loop knows
/// which run and iteration the completion belongs to, and has to stamp a figure on the audit row
/// that becomes `ConversationRunInfo.costRollup`. Without this the loop priced from
/// `conv.model.cost` — the *conversation's* model — which mode-profile routing and ranked fallback
/// can substitute away from, so the ledger and the run rollup billed the same call at different
/// rates, and a conversation whose model row carried no rates reported `$0` on a real charge.
///
/// A `final class` on purpose. `StandardModelLLMFactory` is a struct that gets copied three times on
/// the way to the composition root (`aligningAccounting`, `factoryApplyingTenancyPolicy`,
/// `productionConfigured`); a reference type means every copy shares one sink.
///
/// **Ordering is not a race.** `BudgetEnforcingLLM.stream` settles *before* `continuation.finish()`,
/// and the loop's `for try await` cannot exit until that finish lands — so the write always
/// happens-before the read. The fallback exists for the paths that legitimately record nothing
/// (cancellation, error, a host that wired the sink to only one side), not to paper over a race.
public final class ModelCompletionSettlementSink: Sendable {
    private let settled = Mutex<[UUID: Double]>([:])

    public init() {}

    /// Record what a completion cost, or clear the slot when it cost nothing knowable.
    ///
    /// Cancellations and errors clear rather than leave the previous value in place: a stale figure
    /// picked up by the *next* completion would bill one call's tokens at another call's price.
    public func record(conversationID: UUID?, costUSD: Double?) {
        guard let conversationID else { return }
        settled.withLock { store in
            if let costUSD {
                store[conversationID] = costUSD
            } else {
                store.removeValue(forKey: conversationID)
            }
        }
    }

    /// Take the settled figure for a conversation, clearing it.
    ///
    /// Consuming rather than peeking is what keeps a completion that recorded nothing from
    /// inheriting the previous one's price.
    public func consume(conversationID: UUID) -> Double? {
        settled.withLock { $0.removeValue(forKey: conversationID) }
    }
}
