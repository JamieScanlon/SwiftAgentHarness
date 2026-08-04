import Foundation
import Logging

/// What the ladder wants the owner told.
struct TriggerBudgetBreachNotice: Sendable, Equatable {
    var rung: TriggerBudgetRung
    var scopeKey: String
    var windowKey: String
    var spentUSD: Double
    var ceilingUSD: Double
    var trigger: HarnessTrigger

    var message: String {
        let spent = String(format: "%.2f", spentUSD)
        let ceiling = String(format: "%.2f", ceilingUSD)
        switch rung {
        case .warn:
            return "Automation budget warning: \(scopeKey) has used $\(spent) of its $\(ceiling) budget for \(windowKey)."
        case .deferFires:
            return "Automation budget reached: \(scopeKey) has used $\(spent) of $\(ceiling) for \(windowKey). Further runs are paused until the next window."
        case .suspend:
            return "Automation suspended: \(scopeKey) has exhausted its $\(ceiling) budget for several windows running. It will not fire again until you re-enable it."
        }
    }
}

/// Host-supplied meter.
///
/// The harness knows which conversation belongs to which trigger source — it created it. The host
/// knows what a conversation cost, from the authoritative per-run usage rollups. This port is that
/// one number and nothing else.
struct TriggerSpendPorts: Sendable {
    /// Settled USD for a finished trigger-host conversation. `nil` means "not settled yet" — the
    /// charge stays pending and is retried on the next admission.
    var conversationCostUSD: @Sendable (_ conversationID: UUID) async -> Double?
    /// Deliver a breach notice to the owner through the origin channel captured at registration.
    var notify: @Sendable (TriggerBudgetBreachNotice) async -> Void

    init(
        conversationCostUSD: @escaping @Sendable (_ conversationID: UUID) async -> Double?,
        notify: @escaping @Sendable (TriggerBudgetBreachNotice) async -> Void
    ) {
        self.conversationCostUSD = conversationCostUSD
        self.notify = notify
    }

    /// No meter and no notifier. Admission still refuses a *suspended* source, but no spend ever
    /// accrues, so ceilings never bind — the gate logs this loudly at construction rather than
    /// presenting an unmetered ceiling as enforcement.
    static let unmetered = TriggerSpendPorts(
        conversationCostUSD: { _ in nil },
        notify: { _ in }
    )
}

enum TriggerBudgetAdmission: Sendable, Equatable {
    case admit
    case refuse(rung: TriggerBudgetRung, scopeKey: String)
}

/// Activation-policy stage 4: the gate denominated in spend.
///
/// Rate limits cap *events*; a trigger's cost per event is unbounded, so a fire count is not a cost
/// proxy. This gate answers one question — has this source's ledger reached its ceiling for the
/// window? — against recorded history, so the check is exact rather than estimated. The overshoot is
/// bounded by whatever per-run caps the task carries, not by this gate.
struct TriggerBudgetGate: Sendable {
    private let store: TriggerSpendLedgerStore
    private let configuration: TriggerBudgetConfiguration
    private let ports: TriggerSpendPorts
    private let logger: Logger

    init(
        store: TriggerSpendLedgerStore,
        configuration: TriggerBudgetConfiguration,
        ports: TriggerSpendPorts,
        logger: Logger
    ) {
        self.store = store
        self.configuration = configuration
        self.ports = ports
        self.logger = logger
    }

    /// Stable ledger identity for a trigger's source: the specific route / job / peer where one
    /// exists, falling back to the source kind.
    static func sourceKey(for trigger: HarnessTrigger) -> String {
        let metadata = trigger.sourceMetadata
        let specific = metadata["cronJobId"]
            ?? metadata["routeName"]
            ?? metadata["chatId"]
            ?? trigger.initiator.id
        guard let specific, !specific.isEmpty else { return trigger.source.rawValue }
        return "\(trigger.source.rawValue):\(specific)"
    }

    // MARK: - Admission

    func admit(_ trigger: HarnessTrigger, now: Date = Date()) async -> TriggerBudgetAdmission {
        guard configuration.enabled else { return .admit }
        let key = Self.sourceKey(for: trigger)

        // Drain anything this source ran but has not paid for yet, so admission sees real history.
        await settlePending(sourceKey: key, now: now)

        let budgets = configuration.applicable(sourceKey: key, trust: trigger.trust)
        guard !budgets.isEmpty else { return .admit }

        do {
            // `load`, not `mutate`. Admission decides nothing that needs writing, and taking the
            // read-modify-write path made every admission re-encode the whole ledger, create the
            // file for sources that had never spent, and run retention — so a decision could
            // silently drop a pending charge as a side effect.
            let file = try store.load()
            // Checked against the *scope* key, which is what `escalate` writes. These were two
            // different strings — suspension was stored under `source:<key>` and read under the
            // bare `<key>`, so the ladder's terminal rung never refused anything. Every applicable
            // scope is checked, so a future non-source suspension binds too.
            for budget in budgets where file.sources[budget.scope.key]?.suspended == true {
                return .refuse(rung: .suspend, scopeKey: budget.scope.key)
            }
            // Refuse if *any* applicable ledger is at its ceiling — otherwise a per-source budget
            // would let a source keep spending after the global pot is empty.
            for budget in budgets {
                let windowKey = budget.window.key(for: now)
                let entryKey = TriggerSpendLedgerFile.entryKey(scopeKey: budget.scope.key, windowKey: windowKey)
                let spent = file.entries[entryKey]?.spentUSD ?? 0
                if budget.rung(forSpent: spent) == .deferFires {
                    return .refuse(rung: .deferFires, scopeKey: budget.scope.key)
                }
            }
            return .admit
        } catch {
            // Fail open on ledger IO, and say so. Refusing every trigger because a file is
            // unreadable turns a bookkeeping fault into an outage of the user's automations.
            logger.error("trigger_budget_ledger_unavailable error=\(String(describing: error))")
            return .admit
        }
    }

    // MARK: - Charging

    /// Record that a trigger run is outstanding. Called once the run has a conversation to bill.
    ///
    /// Only isolated and delegated routes are indexed: those get their own trigger-host conversation,
    /// so the whole conversation's cost belongs to the source. A threaded fire shares the user's
    /// conversation with the human's own turns, and billing that conversation would charge the user's
    /// typing to their reminder.
    func indexRun(trigger: HarnessTrigger, conversationID: UUID, now: Date = Date()) {
        guard configuration.enabled else { return }
        let charge = TriggerPendingRunCharge(
            sourceKey: Self.sourceKey(for: trigger),
            trust: trigger.trust,
            conversationID: conversationID,
            triggerID: trigger.id,
            firedAtMs: Int64(now.timeIntervalSince1970 * 1000),
            dayWindowKey: TriggerBudgetWindow.day.key(for: now),
            monthWindowKey: TriggerBudgetWindow.month.key(for: now),
            originMetadata: trigger.sourceMetadata.filter { $0.key.hasPrefix("origin") }
        )
        do {
            try store.mutate(now: now) { file in
                file.pending.append(charge)
            }
        } catch {
            logger.error("trigger_budget_index_failed trigger=\(trigger.id) error=\(String(describing: error))")
        }
    }

    /// Settle outstanding runs for one source and walk the ladder for anything that breached.
    func settlePending(sourceKey: String, now: Date = Date()) async {
        guard configuration.enabled else { return }
        let outstanding: [TriggerPendingRunCharge]
        do {
            outstanding = try store.load().pending.filter { $0.sourceKey == sourceKey }
        } catch {
            logger.error("trigger_budget_settle_read_failed error=\(String(describing: error))")
            return
        }
        guard !outstanding.isEmpty else { return }

        var settled: [(charge: TriggerPendingRunCharge, costUSD: Double)] = []
        for charge in outstanding {
            // `nil` means the host has not settled this conversation yet — leave it pending and try
            // again on the next admission rather than charging a guess.
            guard let cost = await ports.conversationCostUSD(charge.conversationID) else { continue }
            settled.append((charge, max(0, cost)))
        }
        guard !settled.isEmpty else { return }

        var notices: [TriggerBudgetBreachNotice] = []
        do {
            notices = try store.mutate(now: now) { file in
                var produced: [TriggerBudgetBreachNotice] = []
                let settledIDs = Set(settled.map(\.charge.conversationID))
                file.pending.removeAll { settledIDs.contains($0.conversationID) }
                for (charge, cost) in settled {
                    let budgets = configuration.applicable(sourceKey: charge.sourceKey, trust: charge.trust)
                    for budget in budgets {
                        let windowKey = budget.window == .day ? charge.dayWindowKey : charge.monthWindowKey
                        let entryKey = TriggerSpendLedgerFile.entryKey(scopeKey: budget.scope.key, windowKey: windowKey)
                        var entry = file.entries[entryKey] ?? TriggerSpendLedgerEntry(
                            scopeKey: budget.scope.key,
                            windowKey: windowKey,
                            spentUSD: 0,
                            chargedRuns: 0,
                            lastChargedAtMs: 0,
                            notifiedRung: nil
                        )
                        entry.spentUSD += cost
                        entry.chargedRuns += 1
                        entry.lastChargedAtMs = Int64(now.timeIntervalSince1970 * 1000)

                        if let rung = budget.rung(forSpent: entry.spentUSD) {
                            let alreadyNotified = entry.notifiedRung?.rung
                            if alreadyNotified == nil || alreadyNotified! < rung {
                                entry.notifiedRung = TriggerBudgetRungRecord(rung)
                                produced.append(
                                    TriggerBudgetBreachNotice(
                                        rung: rung,
                                        scopeKey: budget.scope.key,
                                        windowKey: windowKey,
                                        spentUSD: entry.spentUSD,
                                        ceilingUSD: budget.ceilingUSD,
                                        trigger: noticeTrigger(for: charge)
                                    )
                                )
                            }
                            if rung == .deferFires, budget.scope.isSourceScoped {
                                if let escalation = escalate(
                                    file: &file,
                                    scopeKey: budget.scope.key,
                                    windowKey: windowKey,
                                    budget: budget,
                                    charge: charge,
                                    spent: entry.spentUSD
                                ) {
                                    produced.append(escalation)
                                }
                            }
                        }
                        file.entries[entryKey] = entry
                    }
                }
                return produced
            }
        } catch {
            logger.error("trigger_budget_settle_write_failed error=\(String(describing: error))")
            return
        }

        for notice in notices {
            logger.warning(
                "trigger_budget_breach rung=\(notice.rung.rawValue) scope=\(notice.scopeKey) window=\(notice.windowKey) spent=\(String(format: "%.4f", notice.spentUSD)) ceiling=\(String(format: "%.2f", notice.ceilingUSD))"
            )
            // Every rung notifies. A trigger the user registered is a standing instruction; making
            // it silently stop firing is a correctness bug wearing a cost-control costume.
            await ports.notify(notice)
        }
    }

    /// A source that exhausts its ceiling window after window is misconfigured or hostile either
    /// way; escalating on a count keeps the decision mechanical rather than judgemental.
    private func escalate(
        file: inout TriggerSpendLedgerFile,
        scopeKey: String,
        windowKey: String,
        budget: TriggerBudget,
        charge: TriggerPendingRunCharge,
        spent: Double
    ) -> TriggerBudgetBreachNotice? {
        var state = file.sources[scopeKey] ?? TriggerSourceBudgetState(
            scopeKey: scopeKey,
            consecutiveBreachedWindows: 0,
            lastBreachedWindowKey: nil,
            suspended: false,
            suspendedAtMs: nil
        )
        guard state.lastBreachedWindowKey != windowKey else { return nil }
        let firedAt = Date(timeIntervalSince1970: Double(charge.firedAtMs) / 1000)
        if let last = state.lastBreachedWindowKey {
            // Settlement lags firing — `chargePostsToFiringWindow` is the same fact from the other
            // side — so a charge that fired in an *older* window can arrive after a newer one has
            // already breached. That is not a gap in the run; ignoring it is. Rewinding here meant
            // a source breaching every single day never suspended, as long as one settlement was
            // late.
            guard windowKey > last else { return nil }
            // A run is only a run if the previous window was breached too. Without this the counter
            // just accumulated: a source that blew its daily ceiling once a month was suspended on
            // the third month and told it had "exhausted its budget for several windows running".
            if last != budget.window.previousKey(for: firedAt) {
                state.consecutiveBreachedWindows = 0
            }
        }
        state.consecutiveBreachedWindows += 1
        state.lastBreachedWindowKey = windowKey
        var notice: TriggerBudgetBreachNotice?
        if !state.suspended, state.consecutiveBreachedWindows >= budget.suspendAfterBreachedWindows {
            state.suspended = true
            state.suspendedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            notice = TriggerBudgetBreachNotice(
                rung: .suspend,
                scopeKey: scopeKey,
                windowKey: windowKey,
                spentUSD: spent,
                ceilingUSD: budget.ceilingUSD,
                trigger: noticeTrigger(for: charge)
            )
        }
        file.sources[scopeKey] = state
        return notice
    }

    /// Minimal trigger shell carrying the origin metadata a notice needs to reach its owner.
    private func noticeTrigger(for charge: TriggerPendingRunCharge) -> HarnessTrigger {
        HarnessTrigger(
            id: charge.triggerID,
            source: .cron,
            sourceMetadata: charge.originMetadata ?? [:],
            payload: "",
            initiator: TriggerInitiator(kind: .system, id: charge.sourceKey),
            trust: charge.trust
        )
    }
}
