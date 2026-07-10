import CryptoKit
import Foundation

struct DreamRecallEntry: Sendable, Codable, Equatable {
    enum Source: String, Sendable, Codable, Equatable {
        case memorySearch = "memory_search"
        case memoryGet = "memory_get"
    }

    let recalledAt: String
    let recallDay: String
    let queryHash: String
    let source: Source
    let filename: String
    let score: Double
    let snippet: String
    let corpus: String?

    init(
        recalledAt: String,
        recallDay: String,
        queryHash: String,
        source: Source,
        filename: String,
        score: Double,
        snippet: String,
        corpus: String? = nil
    ) {
        self.recalledAt = recalledAt
        self.recallDay = recallDay
        self.queryHash = queryHash
        self.source = source
        self.filename = filename
        self.score = score
        self.snippet = snippet
        self.corpus = corpus
    }
}

struct DreamRecallStats: Sendable, Equatable {
    let filename: String
    let recallCount: Int
    let uniqueQueryCount: Int
    let meanScore: Double
    let latestRecallDay: String
    let snippet: String
}

struct DreamRecallStore: Sendable {
    static let recallsFilename = "recalls.jsonl"
    static let lastDeepFilename = "last-deep.json"
    static let defaultLookbackDays = 30
    static let maxSnippetLength = 300

    let memoryDirectory: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        memoryDirectory: URL,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.memoryDirectory = memoryDirectory
        self.calendar = calendar
        self.now = now
    }

    var dreamsDirectory: URL {
        memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
    }

    var recallsURL: URL {
        dreamsDirectory.appendingPathComponent(Self.recallsFilename)
    }

    var lastDeepURL: URL {
        dreamsDirectory.appendingPathComponent(Self.lastDeepFilename)
    }

    func ensureDreamsDirectory() throws {
        try FileManager.default.createDirectory(at: dreamsDirectory, withIntermediateDirectories: true)
    }

    static func normalizeQuery(_ query: String) -> String {
        query
            .lowercased()
            .split { $0.isWhitespace || $0.isNewline }
            .joined(separator: " ")
    }

    static func queryHash(for query: String) -> String {
        let normalized = normalizeQuery(query)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func getQueryHash(filename: String) -> String {
        queryHash(for: "get:\(filename)")
    }

    func recordSearchHits(query: String, hits: [MemorySearchHit]) throws {
        guard !hits.isEmpty else { return }
        let stamp = now()
        let day = Self.dayString(from: stamp, calendar: calendar)
        let recalledAt = Self.isoString(from: stamp)
        let hash = Self.queryHash(for: query)
        let entries = hits.map { hit in
            DreamRecallEntry(
                recalledAt: recalledAt,
                recallDay: day,
                queryHash: hash,
                source: .memorySearch,
                filename: hit.filename,
                score: hit.score,
                snippet: String(hit.snippet.prefix(Self.maxSnippetLength)),
                corpus: hit.provenance.corpus
            )
        }
        try append(entries)
    }

    func recordGet(filename: String, snippet: String, score: Double = 1.0) throws {
        let stamp = now()
        let entry = DreamRecallEntry(
            recalledAt: Self.isoString(from: stamp),
            recallDay: Self.dayString(from: stamp, calendar: calendar),
            queryHash: Self.getQueryHash(filename: filename),
            source: .memoryGet,
            filename: filename,
            score: score,
            snippet: String(snippet.prefix(Self.maxSnippetLength))
        )
        try append([entry])
    }

    func loadEntries() throws -> [DreamRecallEntry] {
        try ensureDreamsDirectory()
        guard FileManager.default.fileExists(atPath: recallsURL.path) else { return [] }
        let text = try String(contentsOf: recallsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var entries: [DreamRecallEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(DreamRecallEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries
    }

    func aggregateStats(lookbackDays: Int = Self.defaultLookbackDays) throws -> [DreamRecallStats] {
        let cutoffDay = Self.dayString(
            from: calendar.date(byAdding: .day, value: -lookbackDays, to: now()) ?? now(),
            calendar: calendar
        )
        let entries = try loadEntries().filter { $0.recallDay >= cutoffDay }
        var byFile: [String: [DreamRecallEntry]] = [:]
        for entry in entries {
            byFile[entry.filename, default: []].append(entry)
        }
        return byFile.map { filename, rows in
            let uniqueQueries = Set(rows.map(\.queryHash)).count
            let meanScore = rows.map(\.score).reduce(0, +) / Double(rows.count)
            let latestDay = rows.map(\.recallDay).max() ?? ""
            let snippet = rows.last?.snippet ?? ""
            return DreamRecallStats(
                filename: filename,
                recallCount: rows.count,
                uniqueQueryCount: uniqueQueries,
                meanScore: meanScore,
                latestRecallDay: latestDay,
                snippet: snippet
            )
        }
        .sorted { $0.filename < $1.filename }
    }

    func previouslyPromotedFilenames() -> Set<String> {
        DreamPromotionLedger(memoryDirectory: memoryDirectory).previouslyPromotedSourceFilenames()
    }

    private func append(_ entries: [DreamRecallEntry]) throws {
        guard !entries.isEmpty else { return }
        try ensureDreamsDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pathKey = memoryDirectory.standardizedFileURL.path
        let processLock = DreamRecallPathLocks.lock(for: pathKey)
        processLock.lock()
        defer { processLock.unlock() }
        // flock alone is insufficient for cooperative Swift tasks in one process;
        // pair an in-process NSLock with the advisory file lock.
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory) {
            var chunk = ""
            for entry in entries {
                let data = try encoder.encode(entry)
                guard let line = String(data: data, encoding: .utf8) else { continue }
                chunk += line
                chunk += "\n"
            }
            let existing = (try? String(contentsOf: recallsURL, encoding: .utf8)) ?? ""
            try MemoryFileLock.atomicWrite(text: existing + chunk, to: recallsURL)
        }
    }

    static func dayString(from date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func conceptualRichness(snippet: String) -> Double {
        let tokens = snippet
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
        guard !tokens.isEmpty else { return 0 }
        let unique = Set(tokens).count
        return min(1.0, Double(unique) / Double(tokens.count))
    }

    static func recencySignal(latestRecallDay: String, today: String) -> Double {
        guard let latest = parseDay(latestRecallDay), let nowDay = parseDay(today) else { return 0 }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: latest, to: nowDay).day ?? 0
        let age = max(0, days)
        return exp(-Double(age) / 14.0)
    }

    private static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

/// In-process serialization for recall appends. `flock` alone does not serialize
/// concurrent cooperative Swift tasks that open the lock file with truncate semantics.
/// Map mutation is guarded by `mapLock` (same pattern as `GitRootResolver` cache).
enum DreamRecallPathLocks {
    private static let mapLock = NSLock()
    private nonisolated(unsafe) static var locks: [String: NSLock] = [:]

    static func lock(for path: String) -> NSLock {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSLock()
        locks[path] = created
        return created
    }
}
