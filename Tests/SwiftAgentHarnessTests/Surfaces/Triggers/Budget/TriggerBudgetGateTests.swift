import Foundation
import Logging
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// First coverage for the spend gate.
///
/// The whole machine — persisted ledger, rung ladder, escalation, suspension — shipped with no test
/// at all, because the one input it needs (`conversationCostUSD`) is a host-supplied seam that is
/// `nil` in this package. Every ledger read therefore returned `0`, every ceiling admitted, and the
/// gate looked fine from the outside. These tests supply the meter, which is the only thing that
/// makes any of it observable.
@Suite("TriggerBudgetGate")
struct TriggerBudgetGateTests {
    // MARK: - Fixture

    /// The host meter. `nil` for a conversation means "not settled yet", which the gate must treat
    /// as *retry later* rather than *free*.
    final class Meter: Sendable {
        private struct State {
            var costs: [UUID: Double] = [:]
            var lookups = 0
        }

        private let state = Mutex(State())

        func settle(_ conversationID: UUID, at cost: Double) {
            state.withLock { $0.costs[conversationID] = cost }
        }

        var lookupCount: Int {
            state.withLock { $0.lookups }
        }

        var port: @Sendable (UUID) async -> Double? {
            { [self] id in
                state.withLock { state in
                    state.lookups += 1
                    return state.costs[id]
                }
            }
        }
    }

    final class NoticeLog: Sendable {
        private let storage = Mutex<[TriggerBudgetBreachNotice]>([])

        var notices: [TriggerBudgetBreachNotice] {
            storage.withLock { $0 }
        }

        var port: @Sendable (TriggerBudgetBreachNotice) async -> Void {
            { [self] notice in
                storage.withLock { $0.append(notice) }
            }
        }
    }

    private struct Fixture {
        var gate: TriggerBudgetGate
        var store: TriggerSpendLedgerStore
        var meter: Meter
        var notices: NoticeLog
        var fileURL: URL
    }

    private func makeFixture(configuration: TriggerBudgetConfiguration) -> Fixture {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trigger-budget-\(UUID().uuidString)")
            .appendingPathComponent("trigger_spend_ledger.json")
        let store = TriggerSpendLedgerStore(fileURL: fileURL)
        let meter = Meter()
        let notices = NoticeLog()
        let gate = TriggerBudgetGate(
            store: store,
            configuration: configuration,
            ports: TriggerSpendPorts(conversationCostUSD: meter.port, notify: notices.port),
            logger: Logger(label: "test")
        )
        return Fixture(gate: gate, store: store, meter: meter, notices: notices, fileURL: fileURL)
    }

    /// `webhook:deploy` under `sourceKey(for:)`.
    private func deployTrigger(trust: CommEnvelopeOriginTrust = .knownParty) -> HarnessTrigger {
        HarnessTrigger(
            id: "trigger-1",
            source: .webhook,
            sourceMetadata: ["routeName": "deploy"],
            payload: "go",
            initiator: TriggerInitiator(kind: .external, id: "ci"),
            trust: trust
        )
    }

    private static let sourceKey = "webhook:deploy"
    private static let sourceScopeKey = "source:webhook:deploy"

    /// A fixed base rather than `Date()`, so a run that straddles midnight cannot change the window
    /// keys under the test.
    private static let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Self.base) ?? Self.base
    }

    private func sourceOnly(
        ceilingUSD: Double,
        warnFraction: Double = 0.75,
        suspendAfterBreachedWindows: Int = 3
    ) -> TriggerBudgetConfiguration {
        TriggerBudgetConfiguration(
            enabled: true,
            global: nil,
            trustClassDefaults: [:],
            perSource: [
                Self.sourceKey: TriggerBudget(
                    scope: .source(Self.sourceKey),
                    window: .day,
                    ceilingUSD: ceilingUSD,
                    warnFraction: warnFraction,
                    suspendAfterBreachedWindows: suspendAfterBreachedWindows
                )
            ]
        )
    }

    /// Run one billed fire in its own conversation: index it, tell the meter the conversation's
    /// cumulative cost, settle.
    @discardableResult
    private func fire(_ fixture: Fixture, cost: Double, on date: Date) async -> UUID {
        let conversationID = UUID()
        fixture.gate.indexRun(trigger: deployTrigger(), conversationID: conversationID, now: date)
        fixture.meter.settle(conversationID, at: cost)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: date)
        return conversationID
    }

    /// Run one fire in a conversation that is *reused* — the real shape for an isolated trigger,
    /// where `TriggerSessionRouter` hands back the same conversation for a stable session key.
    /// `runningTotal` is what the meter reports afterwards, i.e. cumulative.
    private func fire(
        _ fixture: Fixture,
        in conversationID: UUID,
        runningTotal: Double,
        on date: Date
    ) async {
        fixture.gate.indexRun(trigger: deployTrigger(), conversationID: conversationID, now: date)
        fixture.meter.settle(conversationID, at: runningTotal)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: date)
    }

    // MARK: - Admission and charging

    @Test("an unspent source is admitted")
    func admitsWithNoSpend() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10))
        #expect(await fixture.gate.admit(deployTrigger(), now: day(0)) == .admit)
        // Admission decides nothing that needs writing. It used to take the read-modify-write path,
        // which meant every decision re-encoded the ledger and created a file for a source that had
        // never spent a cent.
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path) == false)
    }

    /// Every applicable ledger is charged, not just the governing one — otherwise a per-source
    /// budget would let a source spend against its own pot while hiding the dollars from the global
    /// one.
    @Test("one fire is charged to every applicable ledger")
    func chargesEveryApplicableLedger() async throws {
        let configuration = TriggerBudgetConfiguration(
            enabled: true,
            global: TriggerBudget(scope: .global, window: .day, ceilingUSD: 100),
            trustClassDefaults: [.knownParty: TriggerBudget(scope: .trustClass(.knownParty), ceilingUSD: 50)],
            perSource: [Self.sourceKey: TriggerBudget(scope: .source(Self.sourceKey), ceilingUSD: 10)]
        )
        let fixture = makeFixture(configuration: configuration)
        await fire(fixture, cost: 3, on: day(0))

        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let file = try fixture.store.load()
        for scopeKey in [Self.sourceScopeKey, "trust:\(CommEnvelopeOriginTrust.knownParty.rawValue)", "global"] {
            let entry = try #require(file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: scopeKey, windowKey: windowKey)])
            #expect(entry.spentUSD == 3)
            #expect(entry.chargedRuns == 1)
        }
    }

    @Test("reaching the ceiling refuses further fires, naming the breached scope")
    func ceilingRefuses() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 5))
        await fire(fixture, cost: 5, on: day(0))
        #expect(
            await fixture.gate.admit(deployTrigger(), now: day(0))
                == .refuse(rung: .deferFires, scopeKey: Self.sourceScopeKey)
        )
    }

    /// The warn rung is a notification, not a refusal — a trigger the user registered is a standing
    /// instruction, and silently stopping it is a correctness bug wearing a cost-control costume.
    @Test("the warn rung notifies but still admits")
    func warnDoesNotRefuse() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10, warnFraction: 0.5))
        await fire(fixture, cost: 6, on: day(0))
        #expect(await fixture.gate.admit(deployTrigger(), now: day(0)) == .admit)
        let notice = try #require(fixture.notices.notices.first)
        #expect(notice.rung == .warn)
        #expect(notice.scopeKey == Self.sourceScopeKey)
    }

    /// A window rolls the ledger over: yesterday's exhaustion does not refuse today.
    @Test("a new window starts from zero")
    func newWindowResetsSpend() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 5))
        await fire(fixture, cost: 5, on: day(0))
        #expect(await fixture.gate.admit(deployTrigger(), now: day(0)) != .admit)
        #expect(await fixture.gate.admit(deployTrigger(), now: day(1)) == .admit)
    }

    // MARK: - Settlement contract

    /// `nil` means "the host has not settled this conversation yet". Charging a guess, or dropping
    /// the charge, both lose money the ceiling exists to count.
    @Test("an unsettled conversation stays pending and is charged when it settles")
    func unsettledChargeIsRetried() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10))
        let conversationID = UUID()
        fixture.gate.indexRun(trigger: deployTrigger(), conversationID: conversationID, now: day(0))

        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(0))
        #expect(try fixture.store.load().entries.isEmpty)
        #expect(try fixture.store.load().pending.count == 1)
        #expect(fixture.meter.lookupCount == 1)

        fixture.meter.settle(conversationID, at: 4)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(0))
        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        #expect(entry.spentUSD == 4)
        #expect(try fixture.store.load().pending.isEmpty)
        // The charge was re-offered to the meter rather than written off after the first `nil`.
        #expect(fixture.meter.lookupCount == 2)
    }

    @Test("a settled charge is not charged twice")
    func settlementIsIdempotent() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10))
        await fire(fixture, cost: 4, on: day(0))
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(0))
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(0))

        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        #expect(entry.spentUSD == 4)
        #expect(entry.chargedRuns == 1)
    }

    /// A charge belongs to the window it *fired* in, even when the host settles it after rollover —
    /// otherwise a slow settlement would launder yesterday's spend into today's allowance.
    @Test("a charge is posted to the window it fired in, not the window it settled in")
    func chargePostsToFiringWindow() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10))
        let conversationID = UUID()
        fixture.gate.indexRun(trigger: deployTrigger(), conversationID: conversationID, now: day(0))
        fixture.meter.settle(conversationID, at: 6)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(1))

        let file = try fixture.store.load()
        let firedWindow = TriggerBudgetWindow.day.key(for: day(0))
        let settledWindow = TriggerBudgetWindow.day.key(for: day(1))
        #expect(file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: firedWindow)]?.spentUSD == 6)
        #expect(file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: settledWindow)] == nil)
    }

    @Test("a negative cost cannot credit the ledger")
    func negativeCostClamps() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10))
        await fire(fixture, cost: 5, on: day(0))
        await fire(fixture, cost: -100, on: day(0))
        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        #expect(entry.spentUSD == 5)
    }

    /// A trigger-host conversation is reused across fires, so the meter's answer is cumulative and
    /// the ledger must charge the delta. Billing the whole total each time accrues `N²/2` dollars
    /// for `N` dollars of spend — three $1 fires reading 1, 2, 3 would post $6 — and a $10 ceiling
    /// would refuse on the 5th fire instead of the 11th.
    @Test("a reused conversation is charged the delta, not its running total")
    func reusedConversationChargesDelta() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 100))
        let conversationID = UUID()
        for total in [1.0, 2.0, 3.0] {
            await fire(fixture, in: conversationID, runningTotal: total, on: day(0))
        }
        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        #expect(entry.spentUSD == 3)
        #expect(entry.chargedRuns == 3)
    }

    /// The high-water mark is what makes the delta correct across a restart, so it has to be in the
    /// file rather than in memory.
    @Test("the billed high-water mark persists")
    func billedTotalPersists() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 100))
        let conversationID = UUID()
        await fire(fixture, in: conversationID, runningTotal: 4, on: day(0))
        let mark = try #require(try fixture.store.load().billedConversations[conversationID.uuidString])
        #expect(mark.totalUSD == 4)
    }

    /// A meter that reports less than last time — a compaction, a rewritten transcript — must not
    /// credit the ledger back.
    @Test("a meter that goes backwards cannot credit the ledger")
    func decreasingTotalDoesNotCredit() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 100))
        let conversationID = UUID()
        await fire(fixture, in: conversationID, runningTotal: 5, on: day(0))
        await fire(fixture, in: conversationID, runningTotal: 1, on: day(0))
        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        #expect(entry.spentUSD == 5)
        #expect(try fixture.store.load().billedConversations[conversationID.uuidString]?.totalUSD == 5)
    }

    /// Several outstanding charges routinely share one conversation. The meter is expensive — a full
    /// transcript re-derivation per call — so it must be asked once per conversation, not once per
    /// charge.
    @Test("the meter is consulted once per conversation, not once per charge")
    func meterConsultedOncePerConversation() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 100))
        let conversationID = UUID()
        for _ in 0 ..< 3 {
            fixture.gate.indexRun(trigger: deployTrigger(), conversationID: conversationID, now: day(0))
        }
        fixture.meter.settle(conversationID, at: 9)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(0))
        #expect(fixture.meter.lookupCount == 1)
        let windowKey = TriggerBudgetWindow.day.key(for: day(0))
        let entry = try #require(
            try fixture.store.load().entries[
                TriggerSpendLedgerFile.entryKey(scopeKey: Self.sourceScopeKey, windowKey: windowKey)
            ]
        )
        // Three charges, one conversation, one delta — posted once, not three times.
        #expect(entry.spentUSD == 9)
        #expect(entry.chargedRuns == 3)
    }

    // MARK: - The ladder

    /// The regression this suite exists for. Escalation wrote suspension under the *scope* key
    /// (`source:webhook:deploy`) while admission read the bare *source* key (`webhook:deploy`), so
    /// the ladder's terminal rung never refused anything — it recorded a suspension nobody checked.
    @Test("three consecutive breached windows suspend the source, and admission honours it")
    func consecutiveBreachesSuspend() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 1, suspendAfterBreachedWindows: 3))
        for offset in 0..<3 {
            await fire(fixture, cost: 2, on: day(offset))
        }
        let state = try #require(try fixture.store.load().sources[Self.sourceScopeKey])
        #expect(state.suspended)
        #expect(state.consecutiveBreachedWindows == 3)
        #expect(
            await fixture.gate.admit(deployTrigger(), now: day(2))
                == .refuse(rung: .suspend, scopeKey: Self.sourceScopeKey)
        )
        #expect(fixture.notices.notices.filter { $0.rung == .suspend }.count == 1)
    }

    /// Suspension is sticky and outlives the window that caused it — "it will not fire again until
    /// you re-enable it". Before the key was corrected, a suspended source quietly resumed the next
    /// day, because the fresh window's ledger was empty and nothing else refused it.
    @Test("a suspended source stays refused in a later, unspent window")
    func suspensionSurvivesWindowRollover() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 1, suspendAfterBreachedWindows: 3))
        for offset in 0..<3 {
            await fire(fixture, cost: 2, on: day(offset))
        }
        #expect(
            await fixture.gate.admit(deployTrigger(), now: day(30))
                == .refuse(rung: .suspend, scopeKey: Self.sourceScopeKey)
        )
    }

    /// "Consecutive" has to mean consecutive. The counter only ever incremented on a new window key,
    /// so breaches a month apart accumulated: a source that blew its daily ceiling once a month was
    /// suspended on the third month and told it had exhausted its budget "for several windows
    /// running".
    @Test("breaches in non-adjacent windows do not accumulate into a suspension")
    func nonAdjacentBreachesDoNotSuspend() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 1, suspendAfterBreachedWindows: 3))
        for offset in [0, 2, 4, 6] {
            await fire(fixture, cost: 2, on: day(offset))
        }
        let state = try #require(try fixture.store.load().sources[Self.sourceScopeKey])
        #expect(state.suspended == false)
        #expect(state.consecutiveBreachedWindows == 1)
        #expect(await fixture.gate.admit(deployTrigger(), now: day(7)) == .admit)
    }

    /// A run that is broken and then re-established starts over rather than resuming its old count.
    @Test("a broken run restarts the count")
    func brokenRunRestartsCount() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 1, suspendAfterBreachedWindows: 3))
        await fire(fixture, cost: 2, on: day(0))
        await fire(fixture, cost: 2, on: day(1))
        // Gap.
        await fire(fixture, cost: 2, on: day(5))
        await fire(fixture, cost: 2, on: day(6))
        let state = try #require(try fixture.store.load().sources[Self.sourceScopeKey])
        #expect(state.consecutiveBreachedWindows == 2)
        #expect(state.suspended == false)
    }

    /// Settlement lags firing, so a charge that fired in an older window can arrive after a newer
    /// window has already breached. Treating that as a gap rewound the run — a source breaching its
    /// ceiling every single day never suspended, as long as one settlement was late.
    @Test("a late settlement for an older window does not rewind the run")
    func lateSettlementDoesNotRewindTheRun() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 1, suspendAfterBreachedWindows: 3))
        let late = UUID()
        fixture.gate.indexRun(trigger: deployTrigger(), conversationID: late, now: day(0))

        await fire(fixture, cost: 2, on: day(0))
        await fire(fixture, cost: 2, on: day(1))
        // Only now does the host settle the day-0 run.
        fixture.meter.settle(late, at: 2)
        await fixture.gate.settlePending(sourceKey: Self.sourceKey, now: day(1))
        await fire(fixture, cost: 2, on: day(2))

        let state = try #require(try fixture.store.load().sources[Self.sourceScopeKey])
        #expect(state.consecutiveBreachedWindows == 3)
        #expect(state.suspended)
    }

    /// Only source-scoped budgets escalate: suspending a whole trust class, or the globe, because
    /// one misbehaving job exhausted a shared pot would take every other automation down with it.
    @Test("a breached global budget does not suspend anything")
    func globalBreachDoesNotSuspend() async throws {
        let configuration = TriggerBudgetConfiguration(
            enabled: true,
            global: TriggerBudget(scope: .global, window: .day, ceilingUSD: 1, suspendAfterBreachedWindows: 1),
            trustClassDefaults: [:],
            perSource: [:]
        )
        let fixture = makeFixture(configuration: configuration)
        for offset in 0..<3 {
            await fire(fixture, cost: 2, on: day(offset))
        }
        #expect(try fixture.store.load().sources.isEmpty)
        #expect(await fixture.gate.admit(deployTrigger(), now: day(3)) == .admit)
    }

    /// One notice per rung per window, so crossing the warn line does not re-announce on every
    /// subsequent fire — but escalating warn → defer does announce again.
    @Test("each rung is announced once per window")
    func rungAnnouncedOncePerWindow() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 10, warnFraction: 0.5))
        await fire(fixture, cost: 6, on: day(0))
        await fire(fixture, cost: 1, on: day(0))
        #expect(fixture.notices.notices.filter { $0.rung == .warn }.count == 1)
        await fire(fixture, cost: 5, on: day(0))
        #expect(fixture.notices.notices.filter { $0.rung == .deferFires }.count == 1)
    }

    // MARK: - Durability

    /// "A daily ceiling that resets on process restart is a ceiling an attacker resets by crashing
    /// the process." A second store over the same file is that restart.
    @Test("the ledger binds across a restart")
    func ledgerSurvivesRestart() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 5))
        await fire(fixture, cost: 5, on: day(0))

        let reopened = TriggerBudgetGate(
            store: TriggerSpendLedgerStore(fileURL: fixture.fileURL),
            configuration: sourceOnly(ceilingUSD: 5),
            ports: .unmetered,
            logger: Logger(label: "test")
        )
        #expect(
            await reopened.admit(deployTrigger(), now: day(0))
                == .refuse(rung: .deferFires, scopeKey: Self.sourceScopeKey)
        )
    }

    /// Fail *open* on IO, and loudly. Refusing every trigger because one file is unreadable turns a
    /// bookkeeping fault into an outage of the user's automations.
    @Test("an unreadable ledger admits rather than blocking every automation")
    func corruptLedgerFailsOpen() async throws {
        let fixture = makeFixture(configuration: sourceOnly(ceilingUSD: 5))
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: fixture.fileURL)
        #expect(throws: TriggerSpendLedgerError.self) {
            try fixture.store.load()
        }
        #expect(await fixture.gate.admit(deployTrigger(), now: day(0)) == .admit)
        // Failing open must not also mean failing *empty*: the unreadable bytes are still there, so
        // an operator can repair them rather than discovering a silently reset ceiling.
        #expect(try Data(contentsOf: fixture.fileURL) == Data("{ not json".utf8))
    }

    @Test("a disabled configuration neither charges nor refuses")
    func disabledConfigurationIsInert() async throws {
        let fixture = makeFixture(configuration: .disabled)
        await fire(fixture, cost: 1_000, on: day(0))
        #expect(await fixture.gate.admit(deployTrigger(), now: day(0)) == .admit)
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path) == false)
    }

    // MARK: - Source identity

    /// The ledger key decides whose pot a fire spends from, so its precedence is load-bearing.
    @Test("the source key prefers the most specific identifier available")
    func sourceKeyPrecedence() {
        func key(_ metadata: [String: String], initiator: String?) -> String {
            TriggerBudgetGate.sourceKey(
                for: HarnessTrigger(
                    id: "t",
                    source: .webhook,
                    sourceMetadata: metadata,
                    payload: "",
                    initiator: TriggerInitiator(kind: .external, id: initiator),
                    trust: .knownParty
                )
            )
        }
        #expect(key(["cronJobId": "nightly", "routeName": "deploy", "chatId": "c1"], initiator: "i") == "webhook:nightly")
        #expect(key(["routeName": "deploy", "chatId": "c1"], initiator: "i") == "webhook:deploy")
        #expect(key(["chatId": "c1"], initiator: "i") == "webhook:c1")
        #expect(key([:], initiator: "i") == "webhook:i")
        #expect(key([:], initiator: nil) == "webhook")
        // An empty identifier is not an identity — it must not collapse two sources into one pot
        // under a trailing-colon key.
        #expect(key([:], initiator: "") == "webhook")
    }
}

@Suite("TriggerSpendLedgerStore retention")
struct TriggerSpendLedgerStoreTests {
    private func makeStore(retainedWindows: Int) -> TriggerSpendLedgerStore {
        TriggerSpendLedgerStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ledger-\(UUID().uuidString)")
                .appendingPathComponent("trigger_spend_ledger.json"),
            retainedWindows: retainedWindows
        )
    }

    private func entry(scope: String, window: String) -> TriggerSpendLedgerEntry {
        TriggerSpendLedgerEntry(
            scopeKey: scope,
            windowKey: window,
            spentUSD: 1,
            chargedRuns: 1,
            lastChargedAtMs: 0,
            notifiedRung: nil
        )
    }

    /// Retention is denominated in *windows*, and one row exists per scope per window. Counting rows
    /// meant a deployment with fifty sources crossed a ninety-row limit in two days and began
    /// evicting two-day-old history.
    ///
    /// The sharper half: rows in one window share a `windowKey`, and `sorted` is not stable, so once
    /// every row was current-window the eviction set was arbitrary. Anyone able to mint scope keys —
    /// a channel peer id feeds `sourceKey` — could push the count over the limit and evict a *live*
    /// entry, resetting the ceiling it was holding.
    @Test("retention keeps whole windows regardless of how many scopes are in them")
    func retentionIsPerWindowNotPerRow() throws {
        let store = makeStore(retainedWindows: 2)
        let windows = ["2026-01-01", "2026-01-02", "2026-01-03"]
        try store.mutate { file in
            for window in windows {
                for scope in (0..<10).map({ "source:s\($0)" }) {
                    file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: scope, windowKey: window)] =
                        self.entry(scope: scope, window: window)
                }
            }
        }
        let file = try store.load()
        #expect(Set(file.entries.values.map(\.windowKey)) == Set(["2026-01-02", "2026-01-03"]))
        // Every scope in a retained window survives — no arbitrary casualties.
        #expect(file.entries.count == 20)
    }

    @Test("a live window is never evicted to make room for scope count")
    func liveWindowSurvivesScopeExplosion() throws {
        let store = makeStore(retainedWindows: 1)
        try store.mutate { file in
            file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: "global", windowKey: "2026-01-09")] =
                self.entry(scope: "global", window: "2026-01-09")
            for scope in (0..<200).map({ "source:sybil\($0)" }) {
                file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: scope, windowKey: "2026-01-09")] =
                    self.entry(scope: scope, window: "2026-01-09")
            }
        }
        let file = try store.load()
        #expect(file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: "global", windowKey: "2026-01-09")] != nil)
        #expect(file.entries.count == 201)
    }

    private func charge(firedAtMs: Int64, day: String, month: String, id: String) -> TriggerPendingRunCharge {
        TriggerPendingRunCharge(
            sourceKey: "webhook:deploy",
            trust: .knownParty,
            conversationID: UUID(),
            triggerID: id,
            firedAtMs: firedAtMs,
            dayWindowKey: day,
            monthWindowKey: month,
            originMetadata: nil
        )
    }

    private func msAgo(days: Int) -> Int64 {
        Int64(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970 * 1000)
    }

    /// Day (`yyyy-MM-dd`) and month (`yyyy-MM`) keys are two independent series sharing one
    /// dictionary. Ranked together, a month budget's rows inflate the count and evict day history
    /// early — and a combined ranking drops the month rows outright, because every day key of the
    /// same year sorts after every month key of it.
    @Test("day and month windows are retained as separate series")
    func dayAndMonthRetainedSeparately() throws {
        let store = makeStore(retainedWindows: 2)
        try store.mutate { file in
            for window in ["2026-01-01", "2026-01-02", "2026-01-03", "2025-11", "2025-12", "2026-01"] {
                file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: "global", windowKey: window)] =
                    self.entry(scope: "global", window: window)
            }
        }
        let windows = Set(try store.load().entries.values.map(\.windowKey))
        #expect(windows == Set(["2026-01-02", "2026-01-03", "2025-12", "2026-01"]))
    }

    /// Retention judges a charge against the caller's clock, not the wall clock. While it read
    /// `Date()` itself, any caller working with a date other than today had its charge pruned by the
    /// very write that created it — the gate's own fixtures pin a base date, so every billed fire in
    /// this file vanished before it could be settled.
    @Test("retention is measured against the clock the caller passes")
    func retentionUsesTheCallersClock() throws {
        let store = makeStore(retainedWindows: 1)
        let pinned = Date(timeIntervalSince1970: 1_760_000_000)
        try store.mutate(now: pinned) { file in
            file.pending = [
                self.charge(
                    firedAtMs: Int64(pinned.timeIntervalSince1970 * 1000),
                    day: "2025-10-09",
                    month: "2025-10",
                    id: "pinned"
                )
            ]
        }
        #expect(try store.load().pending.map(\.triggerID) == ["pinned"])
    }

    /// The bug this replaced: retention for pending charges was tested against the windows that
    /// still had *entry rows*. A charge fired in the current window has no row yet — the row is
    /// created at settlement — so the charge was deleted at the moment it was written, and that run
    /// went silently unbilled.
    @Test("a pending charge in a window with no ledger row yet is not pruned")
    func pendingChargeInUnrecordedWindowSurvives() throws {
        let store = makeStore(retainedWindows: 2)
        try store.mutate { file in
            for window in ["2026-01-01", "2026-01-02", "2026-01-03"] {
                file.entries[TriggerSpendLedgerFile.entryKey(scopeKey: "global", windowKey: window)] =
                    self.entry(scope: "global", window: window)
            }
            file.pending = [
                self.charge(firedAtMs: self.msAgo(days: 0), day: "2026-01-04", month: "2026-01", id: "fresh")
            ]
        }
        #expect(try store.load().pending.map(\.triggerID) == ["fresh"])
    }

    /// A backstop against charges abandoned across the ledger's whole retained history. Age is the
    /// right axis: it is a property of the charge, not of which rows happen to survive retention.
    @Test("a pending charge older than the retention horizon is dropped")
    func stalePendingChargeIsDropped() throws {
        // One month of retention, so a charge 200 days old is unambiguously past the horizon and a
        // charge from yesterday is unambiguously inside it.
        let store = makeStore(retainedWindows: 1)
        try store.mutate { file in
            file.pending = [
                self.charge(firedAtMs: self.msAgo(days: 200), day: "2025-06-01", month: "2025-06", id: "abandoned"),
                self.charge(firedAtMs: self.msAgo(days: 1), day: "2026-01-02", month: "2026-01", id: "live"),
            ]
        }
        #expect(try store.load().pending.map(\.triggerID) == ["live"])
    }

    /// Retention must not be able to empty a ledger that is under its window budget — the whole
    /// point of persisting it is that it survives.
    @Test("a ledger inside the retention window is written and reloaded intact")
    func retainedLedgerReloads() throws {
        let store = makeStore(retainedWindows: 90)
        try store.mutate { file in
            file.entries["x|y"] = self.entry(scope: "x", window: "y")
        }
        #expect(try store.load().entries.isEmpty == false)
    }
}

@Suite("TriggerBudgetWindow")
struct TriggerBudgetWindowTests {
    /// Pinned to Gregorian/UTC because the assertions are about the *strings*, and both sides of the
    /// comparison take the injected calendar. (`escalate` uses `Calendar.current`, which is correct
    /// there — window keys are documented as calendar-aligned in local time.)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(DateComponents(calendar: Self.utc, year: year, month: month, day: day).date)
    }

    @Test("the previous day window crosses month and year boundaries")
    func previousDayKey() throws {
        #expect(TriggerBudgetWindow.day.previousKey(for: try date(2026, 1, 15), calendar: Self.utc) == "2026-01-14")
        #expect(TriggerBudgetWindow.day.previousKey(for: try date(2026, 3, 1), calendar: Self.utc) == "2026-02-28")
        #expect(TriggerBudgetWindow.day.previousKey(for: try date(2026, 1, 1), calendar: Self.utc) == "2025-12-31")
    }

    /// The month branch had no coverage at all, and it is the one where naive date arithmetic goes
    /// wrong: stepping back a month from the 31st has no 31st to land on.
    @Test("the previous month window survives short months and year rollover")
    func previousMonthKey() throws {
        #expect(TriggerBudgetWindow.month.previousKey(for: try date(2026, 1, 15), calendar: Self.utc) == "2025-12")
        #expect(TriggerBudgetWindow.month.previousKey(for: try date(2026, 3, 31), calendar: Self.utc) == "2026-02")
        #expect(TriggerBudgetWindow.month.previousKey(for: try date(2026, 7, 1), calendar: Self.utc) == "2026-06")
    }

    /// The property escalation depends on: stepping back from any date lands in the window whose key
    /// the previous day's own `key(for:)` produces.
    @Test("previousKey agrees with key(for:) on the day before")
    func previousKeyAgreesWithKey() throws {
        for offset in 0..<40 {
            let today = try #require(Self.utc.date(byAdding: .day, value: offset, to: try date(2026, 2, 20)))
            let yesterday = try #require(Self.utc.date(byAdding: .day, value: -1, to: today))
            #expect(
                TriggerBudgetWindow.day.previousKey(for: today, calendar: Self.utc)
                    == TriggerBudgetWindow.day.key(for: yesterday, calendar: Self.utc)
            )
        }
    }
}
