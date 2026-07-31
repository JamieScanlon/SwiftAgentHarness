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
    @discardableResult
    func mutate<T>(_ body: (inout TriggerSpendLedgerFile) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var file = try readUnlocked()
        let result = body(&file)
        prune(&file)
        try writeUnlocked(file)
        return result
    }

    private func prune(_ file: inout TriggerSpendLedgerFile) {
        guard file.entries.count > retainedWindows else { return }
        // Window keys sort lexicographically in chronological order (`yyyy-MM-dd`, `yyyy-MM`).
        let doomed = file.entries.values
            .sorted { $0.windowKey < $1.windowKey }
            .prefix(file.entries.count - retainedWindows)
            .map { TriggerSpendLedgerFile.entryKey(scopeKey: $0.scopeKey, windowKey: $0.windowKey) }
        for key in doomed { file.entries.removeValue(forKey: key) }
    }

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
