import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Dreaming reviewability")
struct DreamingReviewabilityTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-c7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedDailyRecalls(
        memoryDirectory: URL,
        dailyFilename: String,
        snippet: String,
        queries: [String],
        calendar: Calendar,
        now: Date
    ) throws {
        let recalls = DreamRecallStore(memoryDirectory: memoryDirectory, calendar: calendar, now: { now })
        for query in queries {
            try recalls.recordSearchHits(
                query: query,
                hits: [MemorySearchHit.fixture(lookupID: dailyFilename, score: 10.0, snippet: snippet)]
            )
        }
    }

    private func openGatesConfig() -> MemoryConfiguration {
        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        return config
    }

    @Test("sweep with promote writes last-sweep.json and appends DREAMS.md")
    func sweepWritesReportAndDiary() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["alpha", "beta"],
            calendar: calendar,
            now: fixedNow
        )

        try await DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        let reportStore = DreamSweepReportStore(memoryDirectory: dir)
        let report = try #require(try reportStore.read())
        #expect(!report.deepPromoted.isEmpty)
        #expect(report.deepPromoted.allSatisfy { $0.outcome == DreamCandidateOutcome.promoted.rawValue })
        #expect(report.thresholds.minRecallCount == 2)

        let diary = try String(contentsOf: reportStore.diaryURL, encoding: .utf8)
        #expect(diary.contains("# DREAMS"))
        #expect(diary.contains("Deep promoted:"))
        #expect(diary.contains("2026-07-09.md"))
        #expect(!diary.contains("Deep promoted: none"))
    }

    @Test("sweep blocked by gates records reject reasons and diary promoted none")
    func sweepBlockedByGates() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["only-one"],
            calendar: calendar,
            now: fixedNow
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        try await DreamingConsolidationScheduler(
            config: config,
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        let report = try #require(try DreamSweepReportStore(memoryDirectory: dir).read())
        #expect(report.deepPromoted.isEmpty)
        #expect(report.deepRejected.contains {
            $0.rejectReason == DreamRejectReason.belowRecallCount.rawValue
                || $0.rejectReason == DreamRejectReason.belowUniqueQueries.rawValue
        })

        let diary = try String(contentsOf: dir.appendingPathComponent("DREAMS.md"), encoding: .utf8)
        #expect(diary.contains("Deep promoted: none"))
        #expect(diary.contains("belowUniqueQueries") || diary.contains("belowRecallCount"))
    }

    @Test("explain formatter surfaces thresholds and reject reasons")
    func explainFormatter() throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = DreamSweepReport(
            runID: "run-1",
            completedAt: "2026-07-09T00:00:00Z",
            thresholds: DreamThresholdSnapshot(minScore: 0.75, minRecallCount: 2, minUniqueQueries: 2),
            light: [],
            rem: [],
            deepPromoted: [],
            deepRejected: [
                DreamCandidateReport(
                    filename: "2026-07-09.md",
                    signal: 0.4,
                    recallCount: 1,
                    uniqueQueryCount: 1,
                    snippetPreview: "note",
                    outcome: .rejected,
                    rejectReason: .belowMinScore
                ),
            ]
        )
        let text = DreamingReviewFormatter.explain(report: report, memoryDirectory: dir)
        #expect(text.contains("minScore=0.750"))
        #expect(text.contains("belowMinScore"))
        #expect(text.contains("Promoted: none"))
        #expect(DreamingReviewFormatter.explain(report: nil, memoryDirectory: dir).contains("No sweep report yet"))
    }

    @Test("status enrichment includes thresholds and runID when marker present")
    func statusEnrichment() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["alpha", "beta"],
            calendar: calendar,
            now: fixedNow
        )

        try await DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        let controlRoot = dir.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let summary = DreamingControlStore(rootDirectory: controlRoot).statusSummary(
            cronExpr: "0 3 * * *",
            memoryDirectory: dir,
            config: openGatesConfig()
        )
        #expect(summary.contains("Thresholds:"))
        #expect(summary.contains("minScore="))
        #expect(summary.contains("Last deep: runID="))
        #expect(summary.contains("Last sweep:"))
        #expect(summary.contains("Diary:"))
    }

    @Test("rollback leaves DREAMS.md and last-sweep.json")
    func rollbackLeavesReviewability() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["alpha", "beta"],
            calendar: calendar,
            now: fixedNow
        )

        let scheduler = DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        )
        try await scheduler.runSweep(memoryDirectory: dir)
        let diaryBefore = try String(contentsOf: dir.appendingPathComponent("DREAMS.md"), encoding: .utf8)
        let reportBefore = try #require(try DreamSweepReportStore(memoryDirectory: dir).read())

        try await scheduler.runSweep(memoryDirectory: dir, rollback: true)

        #expect(DreamPromotionLedger(memoryDirectory: dir).readLastDeepMarker() == nil)
        #expect(store.listTopicFilenames().isEmpty)
        let diaryAfter = try String(contentsOf: dir.appendingPathComponent("DREAMS.md"), encoding: .utf8)
        #expect(diaryAfter == diaryBefore)
        let reportAfter = try #require(try DreamSweepReportStore(memoryDirectory: dir).read())
        #expect(reportAfter.runID == reportBefore.runID)
    }
}
