import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Dreaming rehydrate + contamination guard")
struct DreamingRehydrateContaminationTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-c6-\(UUID().uuidString)", isDirectory: true)
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

    @Test("deep write payload uses fresh richestSnippet from live daily, not staged snapshot")
    func deepRehydratesLiveSnippet() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        // Low uniqueness so a later richer paragraph wins `richestSnippet` after the daily grows.
        let staged = "grafana grafana grafana note note note"
        try store.appendDailyNote(staged, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: staged,
            queries: ["alpha", "beta"],
            calendar: calendar,
            now: fixedNow
        )

        let scheduler = DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        )
        let candidates = try await scheduler.stageCandidatesForTesting(memoryDirectory: dir)
        let stagedCandidate = try #require(candidates.first { $0.filename == "2026-07-09.md" })
        #expect(stagedCandidate.snippet.contains("grafana grafana"))

        let richer =
            "rich distinctive conceptual tokens dashboard pipeline observability metrics latency"
        let grown = """
        # Daily notes

        \(staged)

        \(richer)
        """
        try MemoryFileLock.atomicWrite(
            text: grown,
            to: store.dailyURL(for: fixedNow, calendar: calendar)
        )

        try await scheduler.promoteCandidatesForTesting(memoryDirectory: dir, candidates: candidates)

        let topics = store.listTopicFilenames()
        let topicName = try #require(topics.first { $0.hasPrefix("reference_2026-07-09_") })
        let topicBody = try #require(try store.readTopicBody(filename: topicName))
        #expect(topicBody.contains(richer))
        let bodyAfterFrontmatter = topicBody.components(separatedBy: "---").last ?? topicBody
        #expect(bodyAfterFrontmatter.contains(richer))
        #expect(!bodyAfterFrontmatter.contains("grafana grafana grafana"))

        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(index.contains(topicName))
        #expect(index.contains("dashboard") || index.contains("observability"))
    }

    @Test("light staging excludes DREAMS.md and .dreams machine artifacts")
    func lightExcludesContaminants() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.appendDailyNote(
            "rich distinctive conceptual tokens for staging",
            date: fixedNow,
            calendar: calendar,
            now: fixedNow
        )
        try MemoryFileLock.atomicWrite(
            text: "# Dreams diary\n\nshould never stage\n",
            to: dir.appendingPathComponent("DREAMS.md")
        )
        try MemoryFileLock.atomicWrite(
            text: "# Index\n",
            to: dir.appendingPathComponent("MEMORY.md")
        )
        let dreams = dir.appendingPathComponent(".dreams", isDirectory: true)
        try FileManager.default.createDirectory(at: dreams, withIntermediateDirectories: true)
        try MemoryFileLock.atomicWrite(
            text: "{\"filename\":\"bogus\"}\n",
            to: dreams.appendingPathComponent("recalls.jsonl")
        )
        try MemoryFileLock.atomicWrite(
            text: "{\"runID\":\"x\"}\n",
            to: dreams.appendingPathComponent("promotions.jsonl")
        )
        try MemoryFileLock.atomicWrite(
            text: "{\"runID\":\"x\",\"promoted\":[]}\n",
            to: dreams.appendingPathComponent("last-deep.json")
        )

        let scored = try await DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        ).stageCandidatesForTesting(memoryDirectory: dir)

        #expect(scored.contains { $0.filename == "2026-07-09.md" })
        #expect(!scored.contains { $0.filename == "DREAMS.md" })
        #expect(!scored.contains { $0.filename == "MEMORY.md" })
        #expect(!scored.contains { $0.filename.contains("recalls") })
        #expect(!scored.contains { $0.filename.contains("promotions") })
        #expect(!scored.contains { $0.filename.contains("last-deep") })
        #expect(!scored.contains { $0.filename.contains(".dreams") })
    }

    @Test("deep skips force-promoted contaminant filenames")
    func deepSkipsContaminantCandidates() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try MemoryFileLock.atomicWrite(
            text: "# Dreams diary\n\nrich distinctive conceptual tokens diary noise\n",
            to: dir.appendingPathComponent("DREAMS.md")
        )

        let contaminant = DreamCandidate(
            filename: "DREAMS.md",
            signal: 1.0,
            snippet: "rich distinctive conceptual tokens diary noise",
            recallCount: 5,
            uniqueQueryCount: 5,
            source: .daily
        )
        try await DreamingConsolidationScheduler(config: openGatesConfig())
            .promoteCandidatesForTesting(memoryDirectory: dir, candidates: [contaminant])

        let store = AgentMemoryStore(memoryDirectory: dir)
        #expect(store.listTopicFilenames().isEmpty)
        let index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        #expect(index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(DreamPromotionLedger(memoryDirectory: dir).readLastDeepMarker() == nil)
    }

    @Test("deep skips .recall source candidates without writing index")
    func deepSkipsRecallSource() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recallCandidate = DreamCandidate(
            filename: "topic_from_recall.md",
            signal: 1.0,
            snippet: "rich distinctive conceptual tokens from recall path",
            recallCount: 5,
            uniqueQueryCount: 5,
            source: .recall
        )
        try await DreamingConsolidationScheduler(config: openGatesConfig())
            .promoteCandidatesForTesting(memoryDirectory: dir, candidates: [recallCandidate])

        let store = AgentMemoryStore(memoryDirectory: dir)
        #expect(store.listTopicFilenames().isEmpty)
        let index = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        #expect(index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("contamination guard recognizes reserved basenames and .dreams paths")
    func guardUnit() {
        #expect(DreamingContaminationGuard.isExcluded(filename: "DREAMS.md"))
        #expect(DreamingContaminationGuard.isExcluded(filename: "dreams.md"))
        #expect(DreamingContaminationGuard.isExcluded(filename: "MEMORY.md"))
        #expect(DreamingContaminationGuard.isExcluded(filename: "recalls.jsonl"))
        #expect(DreamingContaminationGuard.isExcluded(filename: "promotions.jsonl"))
        #expect(DreamingContaminationGuard.isExcluded(filename: "last-deep.json"))
        #expect(DreamingContaminationGuard.isExcluded(filename: ".dreams/recalls.jsonl"))
        #expect(DreamingContaminationGuard.isExcluded(filename: ".dreams/last-deep.json"))
        #expect(!DreamingContaminationGuard.isExcluded(filename: "2026-07-09.md"))
        #expect(!DreamingContaminationGuard.isExcluded(filename: "reference_note.md"))
    }
}
