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
    private static let deepTopN = 3

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
            try rollbackLastPromotionRun(memoryDirectory: memoryDirectory)
            return
        }
        let runID = UUID().uuidString
        let lightCandidates = try stageLightPhase(memoryDirectory: memoryDirectory, dreamsDir: dreamsDir)
        let remCandidates = remPhase(candidates: lightCandidates)
        // Hold `.memory.lock` for the full durable write + reviewability persist (not reentrant).
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory) {
            let deepResult = try deepPhaseAssumingLocked(
                memoryDirectory: memoryDirectory,
                candidates: remCandidates,
                runID: runID
            )
            try persistReviewabilityAssumingLocked(
                memoryDirectory: memoryDirectory,
                runID: runID,
                lightCandidates: lightCandidates,
                remCandidates: remCandidates,
                deepResult: deepResult
            )
        }
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
        let runID = UUID().uuidString
        let remCandidates = remPhase(candidates: candidates)
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory) {
            let deepResult = try deepPhaseAssumingLocked(
                memoryDirectory: memoryDirectory,
                candidates: remCandidates,
                runID: runID
            )
            try persistReviewabilityAssumingLocked(
                memoryDirectory: memoryDirectory,
                runID: runID,
                lightCandidates: candidates,
                remCandidates: remCandidates,
                deepResult: deepResult
            )
        }
    }

    private func persistReviewabilityAssumingLocked(
        memoryDirectory: URL,
        runID: String,
        lightCandidates: [DreamCandidate],
        remCandidates: [DreamCandidate],
        deepResult: DeepPhaseResult
    ) throws {
        let report = DreamSweepReport(
            runID: runID,
            completedAt: DreamRecallStore.isoString(from: now()),
            thresholds: DreamThresholdSnapshot(config: config),
            light: lightCandidates.map { DreamCandidateReport.from(candidate: $0, outcome: .staged) },
            rem: remCandidates.map { DreamCandidateReport.from(candidate: $0, outcome: .rem) },
            deepPromoted: deepResult.promoted,
            deepRejected: deepResult.rejected
        )
        let store = DreamSweepReportStore(memoryDirectory: memoryDirectory)
        try store.writeAssumingLocked(report)
        try store.appendDiaryAssumingLocked(for: report)
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
            guard !DreamingContaminationGuard.isExcluded(filename: daily.filename) else { continue }
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

    private struct DeepPhaseResult: Sendable {
        var promoted: [DreamCandidateReport]
        var rejected: [DreamCandidateReport]
    }

    private func gateRejectReason(for candidate: DreamCandidate) -> DreamRejectReason? {
        if candidate.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptySnippet
        }
        if candidate.signal < config.dreamingMinScore {
            return .belowMinScore
        }
        if candidate.recallCount < config.dreamingMinRecallCount {
            return .belowRecallCount
        }
        if candidate.uniqueQueryCount < config.dreamingMinUniqueQueries {
            return .belowUniqueQueries
        }
        return nil
    }

    /// Durable deep promote. Caller must already hold `MemoryFileLock.withLock`.
    private func deepPhaseAssumingLocked(
        memoryDirectory: URL,
        candidates: [DreamCandidate],
        runID: String
    ) throws -> DeepPhaseResult {
        let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
        let ledger = DreamPromotionLedger(memoryDirectory: memoryDirectory)
        var promotedReports: [DreamCandidateReport] = []
        var rejectedReports: [DreamCandidateReport] = []

        var gated: [DreamCandidate] = []
        for candidate in candidates {
            if let reason = gateRejectReason(for: candidate) {
                rejectedReports.append(
                    DreamCandidateReport.from(candidate: candidate, outcome: .rejected, rejectReason: reason)
                )
            } else {
                gated.append(candidate)
            }
        }

        let sortedGated = gated.sorted { $0.signal > $1.signal }
        let ranked = Array(sortedGated.prefix(Self.deepTopN))
        let rankedSet = Set(ranked.map(\.filename))
        for candidate in sortedGated where !rankedSet.contains(candidate.filename) {
            rejectedReports.append(
                DreamCandidateReport.from(candidate: candidate, outcome: .rejected, rejectReason: .notInTopN)
            )
        }

        let promotedAt = DreamRecallStore.isoString(from: now())
        // Re-read index inside the sweep lock to close the RMW gap vs concurrent writers.
        var index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        var promotedTopics: [String] = []
        var sourceDailies: [String] = []
        var ledgerRecords: [DreamPromotionRecord] = []

        for candidate in ranked {
            if DreamingContaminationGuard.isExcluded(filename: candidate.filename) {
                logger?.info("[Dreaming] skip \(candidate.filename): contamination guard")
                rejectedReports.append(
                    DreamCandidateReport.from(candidate: candidate, outcome: .rejected, rejectReason: .contamination)
                )
                continue
            }
            switch candidate.source {
            case .daily:
                guard let liveBody = try store.readDailyBody(filename: candidate.filename) else {
                    logger?.info("[Dreaming] skip \(candidate.filename): daily missing")
                    rejectedReports.append(
                        DreamCandidateReport.from(candidate: candidate, outcome: .rejected, rejectReason: .dailyMissing)
                    )
                    continue
                }
                guard liveBody.contains(candidate.snippet) else {
                    logger?.info("[Dreaming] skip \(candidate.filename): staged snippet stale")
                    rejectedReports.append(
                        DreamCandidateReport.from(candidate: candidate, outcome: .rejected, rejectReason: .staleSnippet)
                    )
                    continue
                }
                let liveSnippet = String(
                    Self.richestSnippet(from: liveBody).prefix(DreamRecallStore.maxSnippetLength)
                )
                guard !liveSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    logger?.info("[Dreaming] skip \(candidate.filename): live snippet empty")
                    rejectedReports.append(
                        DreamCandidateReport.from(
                            candidate: candidate,
                            outcome: .rejected,
                            rejectReason: .liveSnippetEmpty
                        )
                    )
                    continue
                }
                let topicFilename = Self.promotedTopicFilename(
                    sourceDailyFilename: candidate.filename,
                    snippet: liveSnippet
                )
                let title = Self.promotedTitle(from: liveSnippet)
                let description = String(liveSnippet.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                let topicContent = """
                ---
                name: \(title)
                description: \(description)
                type: reference
                origin: \(DreamPromotionRecord.originDreamingDeep)
                sourceDaily: \(candidate.filename)
                ---
                \(liveSnippet)
                """
                let createdNewFile = (try? store.readTopicBody(filename: topicFilename)) == nil
                if createdNewFile {
                    try store.writeTopicAssumingLocked(filename: topicFilename, content: topicContent)
                }
                let line = "- [\(title)](\(topicFilename)) — \(String(liveSnippet.prefix(100)).replacingOccurrences(of: "\n", with: " "))"
                if !index.contains(topicFilename) {
                    index += (index.isEmpty ? "" : "\n") + line
                }
                promotedTopics.append(topicFilename)
                sourceDailies.append(candidate.filename)
                ledgerRecords.append(
                    DreamPromotionRecord(
                        runID: runID,
                        promotedAt: promotedAt,
                        topicFilename: topicFilename,
                        sourceDaily: candidate.filename,
                        indexLine: line,
                        createdNewFile: createdNewFile,
                        origin: DreamPromotionRecord.originDreamingDeep
                    )
                )
                promotedReports.append(
                    DreamCandidateReport.from(
                        candidate: candidate,
                        outcome: .promoted,
                        promotedTopic: topicFilename
                    )
                )
            case .recall:
                logger?.info("[Dreaming] skip \(candidate.filename): recall source not promotable")
                rejectedReports.append(
                    DreamCandidateReport.from(
                        candidate: candidate,
                        outcome: .rejected,
                        rejectReason: .recallSourceSkipped
                    )
                )
            }
        }

        if !promotedTopics.isEmpty {
            if let capFired = try store.writeIndexAssumingLocked(content: index) {
                logger?.warning("[Dreaming] MEMORY.md truncated at write: \(capFired)")
            }
            try ledger.appendAssumingLocked(ledgerRecords)
            try ledger.writeLastDeepMarkerAssumingLocked(
                DreamLastDeepMarker(
                    runID: runID,
                    promoted: promotedTopics,
                    sourceDailies: Array(Set(sourceDailies)).sorted()
                )
            )
            logger?.info("[Dreaming] promoted \(promotedTopics.count) candidate(s) to MEMORY.md runID=\(runID)")
        }

        return DeepPhaseResult(promoted: promotedReports, rejected: rejectedReports)
    }

    /// Reverses the last tagged deep promotion run: deletes created topics, scrubs MEMORY.md, clears marker.
    /// Nonisolated so CLI / sync callers can reverse without hopping through the actor.
    /// Does not scrub `DREAMS.md` or `last-sweep.json` (reviewability postmortem).
    nonisolated static func rollbackLastPromotionRun(
        memoryDirectory: URL,
        logger: Logger? = nil
    ) throws {
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory) {
            try rollbackLastPromotionRunAssumingLocked(memoryDirectory: memoryDirectory, logger: logger)
        }
    }

    /// Caller must already hold `MemoryFileLock.withLock`.
    nonisolated private static func rollbackLastPromotionRunAssumingLocked(
        memoryDirectory: URL,
        logger: Logger? = nil
    ) throws {
        let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
        let ledger = DreamPromotionLedger(memoryDirectory: memoryDirectory)
        guard let marker = ledger.readLastDeepMarker() else {
            logger?.info("[Dreaming] rollback: no last-deep marker")
            return
        }

        let records: [DreamPromotionRecord]
        if !marker.runID.isEmpty {
            records = try ledger.records(forRunID: marker.runID)
        } else {
            // Legacy marker without runID / ledger rows: scrub index lines only; do not delete files.
            records = marker.promoted.map {
                DreamPromotionRecord(
                    runID: "",
                    promotedAt: "",
                    topicFilename: $0,
                    sourceDaily: nil,
                    indexLine: "",
                    createdNewFile: false,
                    origin: DreamPromotionRecord.originDreamingDeep
                )
            }
        }

        var index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        let filenames = Set(records.map(\.topicFilename) + marker.promoted)
        if !filenames.isEmpty {
            let kept = index
                .components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return false }
                    return !filenames.contains { trimmed.contains($0) }
                }
            index = kept.joined(separator: "\n")
            _ = try store.writeIndexAssumingLocked(content: index)
        }

        for record in records where record.createdNewFile {
            guard let body = try? store.readTopicBody(filename: record.topicFilename) else { continue }
            guard DreamPromotionLedger.topicHasDreamingOrigin(body) else {
                logger?.info("[Dreaming] rollback: leave \(record.topicFilename) (missing origin tag)")
                continue
            }
            let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
                raw: record.topicFilename,
                memoryDirectory: memoryDirectory,
                requireExists: true
            )
            try FileManager.default.removeItem(atPath: path)
            logger?.info("[Dreaming] rollback: deleted \(record.topicFilename)")
        }

        try ledger.clearLastDeepMarkerAssumingLocked()
        logger?.info("[Dreaming] rollback: cleared last-deep marker runID=\(marker.runID)")
    }

    /// Instance wrapper used by `runSweep(rollback: true)`.
    func rollbackLastPromotionRun(memoryDirectory: URL) throws {
        try Self.rollbackLastPromotionRun(memoryDirectory: memoryDirectory, logger: logger)
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
            guard !DreamingContaminationGuard.isExcluded(filename: name) else { continue }
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

    private static func promotedTopicFilename(sourceDailyFilename: String, snippet: String) -> String {
        let day = String(sourceDailyFilename.dropLast(3))
        let slugSource = promotedTitle(from: snippet)
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
        let digest = DreamRecallStore.queryHash(for: snippet)
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
