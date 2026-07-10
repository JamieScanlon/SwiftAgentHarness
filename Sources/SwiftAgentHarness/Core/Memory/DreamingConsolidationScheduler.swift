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

    /// Test seam: REM + deep on pre-staged candidates (for rehydrate / promote assertions).
    func promoteCandidatesForTesting(memoryDirectory: URL, candidates: [DreamCandidate]) async throws {
        let dreamsDir = memoryDirectory.appendingPathComponent(".dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: dreamsDir, withIntermediateDirectories: true)
        let themes = remPhase(candidates: candidates)
        try await deepPhase(memoryDirectory: memoryDirectory, dreamsDir: dreamsDir, candidates: themes)
    }

    private func stageLightPhase(memoryDirectory: URL, dreamsDir: URL) throws -> [DreamCandidate] {
        _ = dreamsDir
        let recallStore = DreamRecallStore(memoryDirectory: memoryDirectory, calendar: calendar, now: now)
        let statsByFile = Dictionary(
            uniqueKeysWithValues: try recallStore.aggregateStats().map { ($0.filename, $0) }
        )
        let promoted = recallStore.previouslyPromotedFilenames()
        let today = DreamRecallStore.dayString(from: now(), calendar: calendar)

        let dailies = Self.recentDailyFilenames(
            in: memoryDirectory,
            lookbackDays: DreamRecallStore.defaultLookbackDays,
            calendar: calendar,
            now: now()
        )
        guard !dailies.isEmpty else { return [] }

        let dailyStats = dailies.compactMap { statsByFile[$0.filename] }
        let maxCount = max(1, dailyStats.map(\.recallCount).max() ?? 1)
        let maxUnique = max(1, dailyStats.map(\.uniqueQueryCount).max() ?? 1)
        let maxMean = max(1e-9, dailyStats.map(\.meanScore).max() ?? 1)

        var candidates: [DreamCandidate] = []
        for daily in dailies {
            let snippet = Self.richestSnippet(from: daily.body)
            guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let richness = DreamRecallStore.conceptualRichness(snippet: snippet)
            let dayKey = String(daily.filename.dropLast(3)) // strip .md
            let recency = DreamRecallStore.recencySignal(latestRecallDay: dayKey, today: today)
            let consolidation = promoted.contains(daily.filename) ? 1.0 : 0.0

            var frequency = 0.0
            var relevance = 0.0
            var diversity = 0.0
            var recallCount = 0
            var uniqueQueryCount = 0
            if let stat = statsByFile[daily.filename] {
                frequency = Double(stat.recallCount) / Double(maxCount)
                relevance = min(1.0, stat.meanScore / maxMean)
                diversity = Double(stat.uniqueQueryCount) / Double(maxUnique)
                recallCount = stat.recallCount
                uniqueQueryCount = stat.uniqueQueryCount
            }

            let signal =
                Self.frequencyWeight * frequency
                + Self.relevanceWeight * relevance
                + Self.diversityWeight * diversity
                + Self.recencyWeight * recency
                + Self.consolidationWeight * consolidation
                + Self.richnessWeight * richness

            candidates.append(
                DreamCandidate(
                    filename: daily.filename,
                    signal: signal,
                    snippet: snippet,
                    recallCount: recallCount,
                    uniqueQueryCount: uniqueQueryCount,
                    source: .daily
                )
            )
        }
        return candidates.sorted { $0.signal > $1.signal }
    }

    private func remPhase(candidates: [DreamCandidate]) -> [DreamCandidate] {
        candidates.map { c in
            DreamCandidate(
                filename: c.filename,
                signal: c.signal + Self.remPhaseBoost,
                snippet: c.snippet,
                recallCount: c.recallCount,
                uniqueQueryCount: c.uniqueQueryCount,
                source: c.source
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
                && !candidate.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let ranked = gated.sorted { $0.signal > $1.signal }.prefix(3)
        guard !ranked.isEmpty else { return }

        var index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        var promotedTopics: [String] = []

        for candidate in ranked {
            switch candidate.source {
            case .daily:
                guard let liveBody = try store.readDailyBody(filename: candidate.filename) else {
                    logger?.info("[Dreaming] skip \(candidate.filename): daily missing")
                    continue
                }
                guard liveBody.contains(candidate.snippet) else {
                    logger?.info("[Dreaming] skip \(candidate.filename): staged snippet stale")
                    continue
                }
                let topicFilename = Self.promotedTopicFilename(from: candidate)
                let title = Self.promotedTitle(from: candidate.snippet)
                let topicContent = """
                ---
                name: \(title)
                description: \(String(candidate.snippet.prefix(120)).replacingOccurrences(of: "\n", with: " "))
                type: reference
                ---
                \(candidate.snippet)
                """
                if (try? store.readTopicBody(filename: topicFilename)) == nil {
                    try store.writeTopic(filename: topicFilename, content: topicContent)
                }
                let line = "- [\(title)](\(topicFilename)) — \(String(candidate.snippet.prefix(100)).replacingOccurrences(of: "\n", with: " "))"
                if !index.contains(topicFilename) {
                    index += (index.isEmpty ? "" : "\n") + line
                }
                promotedTopics.append(topicFilename)
            case .recall:
                let line = "- [\(candidate.filename)](\(candidate.filename)) — \(candidate.snippet)"
                if !index.contains(candidate.filename) {
                    index += (index.isEmpty ? "" : "\n") + line
                }
                promotedTopics.append(candidate.filename)
            }
        }

        guard !promotedTopics.isEmpty else { return }
        if let capFired = try store.writeIndex(content: index) {
            logger?.warning("[Dreaming] MEMORY.md truncated at write: \(capFired)")
        }
        logger?.info("[Dreaming] promoted \(promotedTopics.count) candidate(s) to MEMORY.md")
        let marker = dreamsDir.appendingPathComponent("last-deep.json")
        let payload = ["promoted": promotedTopics]
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
    ) -> [(filename: String, body: String, snippet: String)] {
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
        var results: [(filename: String, body: String, snippet: String)] = []
        for url in contents {
            let name = url.lastPathComponent
            guard AgentMemoryStore.isDailyFilename(name) else { continue }
            let day = String(name.dropLast(3))
            guard day >= cutoff else { continue }
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let snippet = String(richestSnippet(from: body).prefix(DreamRecallStore.maxSnippetLength))
            results.append((filename: name, body: body, snippet: snippet))
        }
        return results
    }

    private static func richestSnippet(from body: String) -> String {
        let paragraphs = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !paragraphs.isEmpty else {
            return String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DreamRecallStore.maxSnippetLength))
        }
        let best = paragraphs.max { a, b in
            DreamRecallStore.conceptualRichness(snippet: a) < DreamRecallStore.conceptualRichness(snippet: b)
        } ?? paragraphs[0]
        return String(best.prefix(DreamRecallStore.maxSnippetLength))
    }

    private static func promotedTitle(from snippet: String) -> String {
        let firstLine = snippet
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Promoted note"
        let cleaned = firstLine
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80))
    }

    private static func promotedTopicFilename(from candidate: DreamCandidate) -> String {
        let day = String(candidate.filename.dropLast(3))
        let slugSource = promotedTitle(from: candidate.snippet)
            .lowercased()
            .map { ch -> Character in
                if ch.isLetter || ch.isNumber { return ch }
                return "-"
            }
        var slug = String(slugSource)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if slug.isEmpty { slug = "note" }
        slug = String(slug.prefix(48))
        let digest = DreamRecallStore.queryHash(for: candidate.snippet)
        let hash = String(digest.prefix(6))
        return "reference_\(day)_\(slug)_\(hash).md"
    }
}

enum DreamCandidateSource: String, Sendable, Equatable {
    case daily
    case recall
}

struct DreamCandidate: Sendable, Equatable {
    let filename: String
    let signal: Double
    let snippet: String
    let recallCount: Int
    let uniqueQueryCount: Int
    let source: DreamCandidateSource
}
