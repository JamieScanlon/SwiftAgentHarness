import Foundation

/// The one place tokens become dollars.
///
/// This arithmetic existed privately inside `BudgetEnforcingLLM`, where its result was handed to
/// `ModelPoolBudgetDispatch` and then discarded. The turn loop needs the same number to stamp on a
/// completion's audit row, and two copies of a pricing formula is how a budget ledger and a run
/// rollup come to disagree by a few percent with nobody able to say which is right.
///
/// **These are catalog rates, not an invoice.** `ModelCatalogCostPresets` is documented as internal
/// routing heuristics, and `ModelCostBudget` is `nil` for many registry rows — in which case this
/// returns `nil` and the caller records tokens without a cost rather than inventing one.
enum ModelCompletionCostMath {
    /// - Returns: `nil` when the model carries no usable rates, so "unpriced" stays distinguishable
    ///   from "free". A ledger that reads a missing price as `$0` is a ceiling that never binds.
    static func usd(
        promptTokens: Int?,
        completionTokens: Int?,
        cost: ModelCostBudget?
    ) -> Double? {
        guard let cost,
              let inputRate = cost.inputPer1MUSD,
              let outputRate = cost.outputPer1MUSD
        else { return nil }
        let prompt = max(0, promptTokens ?? 0)
        let completion = max(0, completionTokens ?? 0)
        guard prompt > 0 || completion > 0 else { return nil }
        // `cachedInputPer1MUSD` is deliberately unused, matching the behaviour this replaced: the
        // harness does not currently carry a cached-token count to apply it to, so a cache-heavy
        // provider is over-reported. Recorded rather than silently approximated.
        let inputUSD = (Double(prompt) / 1_000_000.0) * inputRate
        let outputUSD = (Double(completion) / 1_000_000.0) * outputRate
        return inputUSD + outputUSD
    }
}
