import Foundation

/// Accrued spend for one scope in one window.
struct TriggerSpendLedgerEntry: Codable, Sendable, Equatable {
    var scopeKey: String
    var windowKey: String
    var spentUSD: Double
    var chargedRuns: Int
    var lastChargedAtMs: Int64
    /// Highest rung already announced for this window, so the owner is notified once per rung
    /// rather than on every fire past the threshold.
    var notifiedRung: TriggerBudgetRungRecord?
}

/// Per-scope state that outlives a single window.
struct TriggerSourceBudgetState: Codable, Sendable, Equatable {
    var scopeKey: String
    /// Windows fully breached back to back. Escalates deferral to sticky suspension.
    var consecutiveBreachedWindows: Int
    var lastBreachedWindowKey: String?
    /// Set by the ladder's terminal rung. Cleared only by a human.
    var suspended: Bool
    var suspendedAtMs: Int64?
}

/// `TriggerBudgetRung` is not `Codable` (it is policy, not persisted state); this is its on-disk
/// mirror, decoded leniently so a rung added by a newer build does not fail the whole ledger.
enum TriggerBudgetRungRecord: String, Codable, Sendable, Equatable {
    case warn
    case deferFires = "defer"
    case suspend

    init?(_ rung: TriggerBudgetRung) {
        self.init(rawValue: rung.rawValue)
    }

    var rung: TriggerBudgetRung? {
        TriggerBudgetRung(rawValue: rawValue)
    }
}

/// A trigger run whose cost has not been settled into the ledger yet.
///
/// Recorded when the run is routed, drained on the next admission for that source. The harness knows
/// which conversation belongs to which source (it created it); the host knows what a conversation
/// cost. This record is the join.
struct TriggerPendingRunCharge: Codable, Sendable, Equatable {
    var sourceKey: String
    var trust: CommEnvelopeOriginTrust
    var conversationID: UUID
    var triggerID: String
    var firedAtMs: Int64
    /// The window the fire belongs to — charged there even if settlement happens after rollover.
    var dayWindowKey: String
    var monthWindowKey: String
    /// The `origin*` keys captured at registration, so a breach notice can reach the human who
    /// asked for this trigger even though no live session exists when the ladder fires.
    var originMetadata: [String: String]?
}

struct TriggerSpendLedgerFile: Codable, Sendable {
    var entries: [String: TriggerSpendLedgerEntry]
    var sources: [String: TriggerSourceBudgetState]
    var pending: [TriggerPendingRunCharge]

    init(
        entries: [String: TriggerSpendLedgerEntry] = [:],
        sources: [String: TriggerSourceBudgetState] = [:],
        pending: [TriggerPendingRunCharge] = []
    ) {
        self.entries = entries
        self.sources = sources
        self.pending = pending
    }

    static func entryKey(scopeKey: String, windowKey: String) -> String {
        "\(scopeKey)|\(windowKey)"
    }
}

enum TriggerSpendLedgerError: Error, Equatable {
    /// The ledger file exists and is non-empty but does not decode. Never recovered by truncation:
    /// a ceiling that resets when its file is corrupted is a ceiling an attacker resets.
    case corruptLedgerFile(path: String)
}

/// Persistent spend ledger.
///
/// A daily ceiling that resets on process restart is a ceiling an attacker resets by crashing the
/// process — or by waiting for the nightly deploy. Same locking and atomic-write idiom as
/// `ScheduledTaskStore`.
struct TriggerSpendLedgerStore: Sendable {
    private let fileURL: URL
    private let retainedWindows: Int
    private let lock = NSLock()

    init(fileURL: URL, retainedWindows: Int = 90) {
        self.fileURL = fileURL
        self.retainedWindows = max(1, retainedWindows)
    }

    func load() throws -> TriggerSpendLedgerFile {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked()
    }

    /// Read-modify-write under one lock, so concurrent settlements cannot lose a charge.
    ///
    /// `now` is a parameter because retention is the one part of this store that depends on a clock,
    /// and every other `now` in this subsystem is injectable. Reading `Date()` here instead meant
    /// retention was measured against the wall clock while the charge it judged carried the caller's
    /// clock — so a caller working with any date but today had its writes pruned by the write that
    /// created them.
    @discardableResult
    func mutate<T>(now: Date = Date(), _ body: (inout TriggerSpendLedgerFile) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var file = try readUnlocked()
        let result = body(&file)
        prune(&file, now: now)
        try writeUnlocked(file)
        return result
    }

    /// Retain the newest `retainedWindows` *windows*, not the newest that many *rows*.
    ///
    /// Counting rows conflated retention with scope count: one row exists per scope per window, so a
    /// deployment with fifty sources crossed a ninety-row limit in two days and began evicting
    /// two-day-old history. Worse, rows in the same window share a `windowKey`, and `sorted` is not
    /// stable — once every row was current-window, which rows got dropped was arbitrary, so anyone
    /// able to mint scope keys (a channel peer id feeds `sourceKey`) could push the row count over
    /// the limit and evict a *live* ledger entry, resetting the ceiling it was holding.
    ///
    /// Window keys sort lexicographically in chronological order (`yyyy-MM-dd`, `yyyy-MM`).
    private func prune(_ file: inout TriggerSpendLedgerFile, now: Date) {
        pruneEntries(&file)
        prunePending(&file, now: now)
    }

    private func pruneEntries(_ file: inout TriggerSpendLedgerFile) {
        let all = Set(file.entries.values.map(\.windowKey))
        // Day (`yyyy-MM-dd`) and month (`yyyy-MM`) keys are two independent series sharing one
        // dictionary. Ranking them together let a month budget's rows inflate the count and evict
        // day history early, for no reason a reader of `retainedWindows` would predict.
        var retained = Set(all.filter { $0.count == dayKeyLength }.sorted().suffix(retainedWindows))
        retained.formUnion(all.filter { $0.count == monthKeyLength }.sorted().suffix(retainedWindows))
        // Anything of an unrecognised shape is kept. Dropping rows this code cannot interpret would
        // make a future window granularity silently lose history.
        retained.formUnion(all.filter { $0.count != dayKeyLength && $0.count != monthKeyLength })
        guard retained.count < all.count else { return }
        file.entries = file.entries.filter { retained.contains($0.value.windowKey) }
    }

    /// Drop charges no retained window could still receive.
    ///
    /// Driven off the charge's own `firedAtMs`, never off which windows still have entry rows. A
    /// charge fired in the current window normally has *no* row yet — the row is created at
    /// settlement — so testing it against `entries` deletes charges at the moment they are written.
    /// That is spend silently forgiven, which is the one thing a ledger may not do by accident.
    ///
    /// The horizon is measured in **months** even though most budgets are daily. This store cannot
    /// see which windows are configured, and a charge still postable to a retained month row has to
    /// survive; the asymmetry is deliberate, because being generous costs some re-offering to the
    /// meter and being tight costs money that silently never lands. So this is a backstop against
    /// charges abandoned across the ledger's whole retained history — not a tight bound on the
    /// pending list, which `settlePending` still re-offers in full on every admission for a source.
    private func prunePending(_ file: inout TriggerSpendLedgerFile, now: Date) {
        guard let horizon = Calendar.current.date(byAdding: .month, value: -retainedWindows, to: now) else { return }
        let horizonMs = Int64(horizon.timeIntervalSince1970 * 1000)
        file.pending.removeAll { $0.firedAtMs < horizonMs }
    }

    private let dayKeyLength = 10
    private let monthKeyLength = 7

    private func readUnlocked() throws -> TriggerSpendLedgerFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TriggerSpendLedgerFile()
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return TriggerSpendLedgerFile() }
        guard let file = try? JSONDecoder().decode(TriggerSpendLedgerFile.self, from: data) else {
            throw TriggerSpendLedgerError.corruptLedgerFile(path: fileURL.path)
        }
        return file
    }

    private func writeUnlocked(_ file: TriggerSpendLedgerFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
