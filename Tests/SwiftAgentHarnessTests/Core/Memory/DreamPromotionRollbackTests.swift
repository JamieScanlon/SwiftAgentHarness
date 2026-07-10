import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Dream promotion rollback")
struct DreamPromotionRollbackTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedDailyWithRecalls(
        dir: URL,
        note: String,
        calendar: Calendar,
        fixedNow: Date
    ) throws -> String {
        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        let daily = AgentMemoryStore.dailyFilename(for: fixedNow, calendar: calendar)
        let recalls = DreamRecallStore(memoryDirectory: dir, calendar: calendar, now: { fixedNow })
        for q in ["alpha", "beta"] {
            try recalls.recordSearchHits(
                query: q,
                hits: [MemorySearchHit(filename: daily, score: 10, snippet: note)]
            )
        }
        return daily
    }

    @Test("promote then rollback removes topic, index line, and marker; keeps daily and recalls")
    func promoteThenRollback() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        let daily = try seedDailyWithRecalls(dir: dir, note: note, calendar: calendar, fixedNow: fixedNow)

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        try await scheduler.runSweep(memoryDirectory: dir)

        let store = AgentMemoryStore(memoryDirectory: dir)
        let topicsBefore = store.listTopicFilenames()
        #expect(topicsBefore.contains { $0.hasPrefix("reference_2026-07-09_") })
        let indexBefore = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(indexBefore.contains("reference_2026-07-09_"))
        let ledger = DreamPromotionLedger(memoryDirectory: dir)
        #expect(ledger.readLastDeepMarker() != nil)
        let ledgerRows = try ledger.loadRecords()
        #expect(!ledgerRows.isEmpty)
        #expect(ledgerRows.allSatisfy { $0.origin == DreamPromotionRecord.originDreamingDeep })

        try await scheduler.runSweep(memoryDirectory: dir, rollback: true)

        #expect(store.listTopicFilenames().isEmpty)
        let indexAfter = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        #expect(indexAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(ledger.readLastDeepMarker() == nil)
        #expect(try store.readDailyBody(filename: daily) != nil)
        let recallEntries = try DreamRecallStore(memoryDirectory: dir).loadEntries()
        #expect(!recallEntries.isEmpty)
    }

    @Test("rollback without prior promote is a no-op")
    func rollbackNoOp() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = DreamingConsolidationScheduler(config: .default)
        try await scheduler.runSweep(memoryDirectory: dir, rollback: true)
        #expect(DreamPromotionLedger(memoryDirectory: dir).readLastDeepMarker() == nil)
    }

    @Test("rollback does not delete hand-written topic without dreaming origin")
    func leavesHandWrittenTopic() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        _ = try seedDailyWithRecalls(dir: dir, note: note, calendar: calendar, fixedNow: fixedNow)

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        try await scheduler.runSweep(memoryDirectory: dir)

        let store = AgentMemoryStore(memoryDirectory: dir)
        let promoted = try #require(store.listTopicFilenames().first)
        // Overwrite with hand-edited content missing origin tag
        try store.writeTopic(
            filename: promoted,
            content: """
            ---
            name: Hand edited
            description: keep me
            type: reference
            ---
            operator owned
            """
        )

        try await scheduler.runSweep(memoryDirectory: dir, rollback: true)
        #expect(try store.readTopicBody(filename: promoted) != nil)
        #expect(DreamPromotionLedger(memoryDirectory: dir).readLastDeepMarker() == nil)
    }

    @Test("after promote, light consolidation signal sees source daily")
    func consolidationSignalUsesSourceDaily() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let note = "rich distinctive conceptual tokens grafana dashboard pipeline"
        let daily = try seedDailyWithRecalls(dir: dir, note: note, calendar: calendar, fixedNow: fixedNow)

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        try await scheduler.runSweep(memoryDirectory: dir)

        let promoted = DreamRecallStore(memoryDirectory: dir).previouslyPromotedFilenames()
        #expect(promoted.contains(daily))

        let scored = try await scheduler.stageCandidatesForTesting(memoryDirectory: dir)
        let dailyCandidate = try #require(scored.first { $0.filename == daily })
        #expect(dailyCandidate.signal > 0.1)
    }
}
