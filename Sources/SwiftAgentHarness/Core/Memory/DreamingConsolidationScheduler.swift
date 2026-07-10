import Foundation
import Logging

actor DreamingConsolidationScheduler {
    private static let frequencyWeight = 0.24
    private static let relevanceWeight = 0.30
    private static let diversityWeight = 0.15
    private static let recencyWeight = 0.15
    private static let consolidationWeight = 0.10
    private static let richnessWeight = 0.06
    private static let remPhaseBoost = 0.05

    private let config: MemoryConfiguration
    private let logger: Logger?
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        config: MemoryConfiguration,
        logger: Logger? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.logger = logger
        self.calendar = calendar
        self.now = now
    }

    func runSweep(memoryDirectory: URL, rollback: Bool = false) async throws {
        let dreamsDir = memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: dreamsDir, withIntermediateDirectories: true)
        if rollback {
            try rollbackBackfill(dreamsDir: dreamsDir)
            return
        }
        let candidates = try stageLightPhase(memoryDirectory: memoryDirectory, dreamsDir: dreamsDir)
        let themes = remPhase(candidates: candidates)
        try await deepPhase(
            memoryDirectory: memoryDirectory,
            dreamsDir: dreamsDir,
            candidates: themes
        )
    }

    /// Test seam: light-phase candidates with measured signals (before REM boost).
    func stageCandidatesForTesting(memoryDirectory: URL) throws -> [DreamCandidate] {
        let dreamsDir = memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: dreamsDir, withIntermediateDirectories: true)
        return try stageLightPhase(memoryDirectory: memoryDirectory, dreamsDir: dreamsDir)
    }

    private func stageLightPhase(memoryDirectory: URL, dreamsDir: URL) throws -> [DreamCandidate] {
        _ = dreamsDir
        let recallStore = DreamRecallStore(memoryDirectory: memoryDirectory, calendar: calendar, now: now)
        let stats = try recallStore.aggregateStats()
        let promoted = recallStore.previouslyPromotedFilenames()
        let today = DreamRecallStore.dayString(from: now(), calendar: calendar)

        let maxCount = max(1, stats.map(\.recallCount).max() ?? 1)
        let maxUnique = max(1, stats.map(\.uniqueQueryCount).max() ?? 1)
        let maxMean = max(1e-9, stats.map(\.meanScore).max() ?? 1)

        var byFilename: [String: DreamCandidate] = [:]
        for stat in stats {
            let frequency = Double(stat.recallCount) / Double(maxCount)
            let relevance = min(1.0, stat.meanScore / maxMean)
            let diversity = Double(stat.uniqueQueryCount) / Double(maxUnique)
            let recency = DreamRecallStore.recencySignal(latestRecallDay: stat.latestRecallDay, today: today)
            let consolidation = promoted.contains(stat.filename) ? 1.0 : 0.0
            let richness = DreamRecallStore.conceptualRichness(snippet: stat.snippet)
            let signal =
                Self.frequencyWeight * frequency
                + Self.relevanceWeight * relevance
                + Self.diversityWeight * diversity
                + Self.recencyWeight * recency
                + Self.consolidationWeight * consolidation
                + Self.richnessWeight * richness
            byFilename[stat.filename] = DreamCandidate(
                filename: stat.filename,
                signal: signal,
                snippet: stat.snippet,
                recallCount: stat.recallCount,
                uniqueQueryCount: stat.uniqueQueryCount
            )
        }

        // Optional daily notes: seed with richness-only if not already recalled.
        for daily in Self.recentDailyFilenames(
            in: memoryDirectory,
            lookbackDays: DreamRecallStore.defaultLookbackDays,
            calendar: calendar,
            now: now()
        ) {
            guard byFilename[daily.filename] == nil else { continue }
            let richness = DreamRecallStore.conceptualRichness(snippet: daily.snippet)
            guard richness > 0 else { continue }
            byFilename[daily.filename] = DreamCandidate(
                filename: daily.filename,
                signal: Self.richnessWeight * richness,
                snippet: daily.snippet,
                recallCount: 0,
                uniqueQueryCount: 0
            )
        }

        return Array(byFilename.values).sorted { $0.signal > $1.signal }
    }

    private func remPhase(candidates: [DreamCandidate]) -> [DreamCandidate] {
        candidates.map { c in
            DreamCandidate(
                filename: c.filename,
                signal: c.signal + Self.remPhaseBoost,
                snippet: c.snippet,
                recallCount: c.recallCount,
                uniqueQueryCount: c.uniqueQueryCount
            )
        }
    }

    private func deepPhase(
        memoryDirectory: URL,
        dreamsDir: URL,
        candidates: [DreamCandidate]
    ) async throws {
        let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
        let gated = candidates.filter { candidate in
            candidate.signal >= config.dreamingMinScore
                && candidate.recallCount >= config.dreamingMinRecallCount
                && candidate.uniqueQueryCount >= config.dreamingMinUniqueQueries
        }
        let ranked = gated.sorted { $0.signal > $1.signal }.prefix(3)
        guard !ranked.isEmpty else { return }
        var index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        for candidate in ranked {
            let line = "- [\(candidate.filename)](\(candidate.filename)) — \(candidate.snippet)"
            if !index.contains(candidate.filename) {
                index += (index.isEmpty ? "" : "\n") + line
            }
        }
        if let capFired = try store.writeIndex(content: index) {
            logger?.warning("[Dreaming] MEMORY.md truncated at write: \(capFired)")
        }
        logger?.info("[Dreaming] promoted \(ranked.count) candidate(s) to MEMORY.md")
        let marker = dreamsDir.appendingPathComponent("last-deep.json")
        let payload = ["promoted": ranked.map(\.filename)]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: marker)
    }

    private func rollbackBackfill(dreamsDir: URL) throws {
        let marker = dreamsDir.appendingPathComponent("last-deep.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    private static func recentDailyFilenames(
        in memoryDirectory: URL,
        lookbackDays: Int,
        calendar: Calendar,
        now: Date
    ) -> [(filename: String, snippet: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: memoryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let cutoff = DreamRecallStore.dayString(
            from: calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now,
            calendar: calendar
        )
        let pattern = /^(\d{4})-(\d{2})-(\d{2})\.md$/
        var results: [(filename: String, snippet: String)] = []
        for url in contents {
            let name = url.lastPathComponent
            guard let match = name.wholeMatch(of: pattern) else { continue }
            let day = "\(match.1)-\(match.2)-\(match.3)"
            guard day >= cutoff else { continue }
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            results.append((filename: name, snippet: String(body.prefix(DreamRecallStore.maxSnippetLength))))
        }
        return results
    }
}

struct DreamCandidate: Sendable, Equatable {
    let filename: String
    let signal: Double
    let snippet: String
    let recallCount: Int
    let uniqueQueryCount: Int
}
