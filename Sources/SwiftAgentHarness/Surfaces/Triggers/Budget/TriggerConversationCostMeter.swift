import Foundation
import Logging

/// Cumulative settled USD for a trigger-host conversation, read from the authoritative per-run
/// rollups.
///
/// Cumulative, not per-fire: a trigger-host conversation is reused across fires
/// (`TriggerSessionRouter.resolveOrCreate` returns the same conversation for a stable session key),
/// so this reports the running total and `TriggerBudgetGate` charges the delta against a high-water
/// mark. Reporting a per-fire number is not possible from here — the port is handed a conversation
/// id and nothing else.
///
/// `TriggerSpendPorts.conversationCostUSD` is a host-supplied seam, and it stayed `nil` in this
/// package — so every ledger read returned `0`, every ceiling admitted, and the gate looked fine
/// from the outside. This is the correct implementation of that seam, offered rather than imposed:
/// `Configuration.conversationCostUSD` still wins, and a host with better numbers should supply
/// them.
///
/// **Why not `ModelPoolCostLedger.projectedCostUSD`.** It has the exact required signature, which
/// makes it the obvious thing to reach for and the wrong one. It returns settled *plus pending
/// reservations*, and it stops returning `nil` once a conversation exists — so wiring it posts
/// in-flight projections as if they were final and settles a charge before the run it bills has
/// finished. The contract here is settled dollars, and `nil` genuinely means "ask again later".
///
/// ## What the numbers mean — read this before trusting a ceiling
///
/// `costRollup` sums two differently-sourced figures. Sub-agent completions carry the provider's own
/// reported cost. Main-loop completions carry provider-reported *tokens* priced with the
/// conversation model's catalog rates (`ModelCompletionCostMath`, shared with the budget ledger so
/// the formula cannot drift). Two consequences worth knowing:
///
/// - A model whose registry row has no rates contributes tokens but no cost, so its fires accrue
///   `$0` against the ceiling.
/// - Mode-profile routing and ranked fallback can dispatch a call to a different model than the
///   conversation's; the ledger prices that at the dispatched model's rates while this prices it at
///   the conversation's. Plumbing the settled cost out of `BudgetEnforcingLLM` is the real fix.
///
public struct TriggerConversationCostMeter: Sendable {
    /// Every run belonging to a conversation, newest first. A port rather than a runtime reference:
    /// `ConversationManager` is deliberately confined behind its persistence domain, and a meter
    /// that needs a live session to be tested is a meter that does not get tested.
    private let listRuns: @Sendable (UUID) async -> [ConversationRunInfo]
    /// How long a still-`.open` run may hold up settlement before the terminal runs are billed
    /// without it.
    private let openRunGrace: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: Logger

    public init(
        listRuns: @escaping @Sendable (UUID) async -> [ConversationRunInfo],
        openRunGrace: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.listRuns = listRuns
        self.openRunGrace = openRunGrace
        self.now = now
        self.logger = logger
    }

    /// The port shape `TriggerSpendPorts` wants.
    public var port: @Sendable (UUID) async -> Double? {
        { [self] conversationID in await settledCostUSD(conversationID: conversationID) }
    }

    /// - Returns: the conversation's cumulative settled USD, or `nil` when it has not finished and
    ///   the charge should stay pending.
    public func settledCostUSD(conversationID: UUID) async -> Double? {
        let runs = await listRuns(conversationID)
        // No runs yet is not "free" — the transcript may not have landed. Charging zero here would
        // permanently write off the run, because a settled charge is removed from `pending`.
        guard !runs.isEmpty else { return nil }

        let open = runs.filter { $0.outcome == .open }
        if !open.isEmpty {
            // `.open` is the only in-flight outcome, and an open run's `costRollup` already carries
            // partial mid-run cost — settling now would bill a fraction and never revisit it.
            //
            // A crashed or abandoned run is *not* this case: the derivation reports it as
            // `.errored` / `run_orphaned` on the very next projection, so it settles normally
            // rather than pinning the charge.
            guard let cutoff = staleCutoff(for: open) else { return nil }
            logger.warning(
                """
                trigger_cost_meter_open_run_stale conversation=\(conversationID) \
                runs=\(open.count) oldestStartedAt=\(cutoff) — billing the terminal runs without it
                """
            )
        }

        // A terminal run with no rollup is billed as zero, deliberately. Only delegate completions
        // populate one, so treating `nil` as "not settled" would leave every ordinary trigger fire
        // pending forever — the charge would outlive its window and be written off anyway, having
        // cost a meter lookup on every admission in between.
        return runs
            .filter { $0.outcome != .open }
            .reduce(0) { $0 + ($1.costRollup?.usd ?? 0) }
    }

    /// Non-nil when every open run has been open longer than the grace period.
    ///
    /// The escape hatch exists because nothing in the harness times a run out: a wedged lane in a
    /// live process leaves a run `.open` indefinitely, and without this the charge would sit pending
    /// until retention dropped it — which for the default configuration is years away.
    private func staleCutoff(for open: [ConversationRunInfo]) -> Date? {
        let deadline = now().addingTimeInterval(-openRunGrace)
        var oldest: Date?
        for run in open {
            // A run with no `startedAt` has no age to judge, so it is never stale.
            guard let startedAt = run.startedAt, startedAt < deadline else { return nil }
            oldest = min(oldest ?? startedAt, startedAt)
        }
        return oldest
    }
}

public extension TriggerConversationCostMeter {
    /// Production wiring over the runtime the trigger bundle already holds.
    ///
    /// Paginates to exhaustion: `ConversationRunListFilter` clamps `limit` to 200, and a
    /// conversation that overran that would silently meter only its newest runs.
    static func runRollups(
        runtime: any APILayerChatRuntimeManaging,
        openRunGrace: TimeInterval = 3600,
        logger: Logger
    ) -> TriggerConversationCostMeter {
        TriggerConversationCostMeter(
            listRuns: { conversationID in
                let walk = await drainPages { cursor in
                    await runtime.apiListConversationRuns(
                        conversationID: conversationID,
                        filter: ConversationRunListFilter(limit: pageLimit, cursor: cursor)
                    )
                }
                if walk.truncated {
                    // Runs come back newest-first, so truncation drops the *oldest* — a silent
                    // undercount, which on a spend ceiling is the failure that matters. Said out
                    // loud rather than quietly billing less than was spent.
                    logger.warning(
                        """
                        trigger_cost_meter_runs_truncated conversation=\(conversationID) \
                        collected=\(walk.runs.count) total=\(walk.total.map(String.init) ?? "unknown") \
                        — billing the newest runs only
                        """
                    )
                }
                return walk.runs
            },
            openRunGrace: openRunGrace,
            logger: logger
        )
    }

    /// Page size. `ConversationRunListFilter` clamps to 200, so asking for more is silently ignored.
    static let pageLimit = 200

    /// Follow the cursor to exhaustion.
    ///
    /// A conversation with more runs than one page would otherwise meter only its newest page —
    /// undercounting silently, which on a spend ceiling is the failure mode that matters.
    ///
    /// Separated from the runtime call so the paging rules are testable without conforming to the
    /// whole runtime protocol.
    ///
    /// - Returns: everything collected, whether the walk stopped early, and the server's reported
    ///   total when it offered one — so the caller can tell a complete walk from a bounded one
    ///   rather than inferring it from a count.
    static func drainPages(
        maximumPages: Int = 50,
        fetch: (String?) async -> ConversationRunListResponse
    ) async -> (runs: [ConversationRunInfo], truncated: Bool, total: Int?) {
        var collected: [ConversationRunInfo] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var total: Int?
        // Bounded twice over: a page count, and a cursor the server repeats. A meter that spins is
        // worse than one that undercounts, because it stalls every admission for the source.
        for _ in 0 ..< max(1, maximumPages) {
            let page = await fetch(cursor)
            total = total ?? page.total
            collected.append(contentsOf: page.runs)
            guard let next = page.cursor, !page.runs.isEmpty, seenCursors.insert(next).inserted else {
                return (collected, false, total)
            }
            cursor = next
        }
        // Fell out of the loop with a cursor still on offer: there was more and we stopped.
        return (collected, true, total)
    }
}
