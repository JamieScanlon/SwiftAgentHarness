import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Daily staging tier")
struct DailyStagingTierTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("appendDailyNote creates and appends YYYY-MM-DD.md")
    func appendRoundTrip() throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.appendDailyNote("first note about grafana", date: day, calendar: calendar, now: day)
        try store.appendDailyNote("second note about metrics", date: day, calendar: calendar, now: day)

        let filename = AgentMemoryStore.dailyFilename(for: day, calendar: calendar)
        #expect(filename == "2026-07-09.md")
        let body = try #require(try store.readDailyBody(date: day, calendar: calendar))
        #expect(body.contains("first note about grafana"))
        #expect(body.contains("second note about metrics"))
        #expect(AgentMemoryStore.isDailyFilename(filename))
    }

    @Test("manifest excludes daily files even with fake frontmatter-looking content")
    func manifestExcludesDailies() throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.appendDailyNote("staging only content with unique tokens", date: Date())
        try store.writeTopic(
            filename: "reference_keep.md",
            content: """
            ---
            name: Keep
            description: curated topic
            type: reference
            ---
            body
            """
        )
        let manifest = store.manifest()
        #expect(manifest.contains { $0.filename == "reference_keep.md" })
        #expect(!manifest.contains { AgentMemoryStore.isDailyFilename($0.filename) })
    }

    @Test("light stages daily without prior search; topic recalls are not candidates")
    func lightStagesDailyWithoutSearch() async throws {
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
        try store.writeTopic(
            filename: "topic_only.md",
            content: """
            ---
            name: Topic
            description: curated
            type: reference
            ---
            should not stage
            """
        )
        try DreamRecallStore(memoryDirectory: dir, calendar: calendar, now: { fixedNow }).recordSearchHits(
            query: "topic",
            hits: [MemorySearchHit(filename: "topic_only.md", score: 9, snippet: "should not stage")]
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        let scored = try await DreamingConsolidationScheduler(
            config: config,
            calendar: calendar,
            now: { fixedNow }
        ).stageCandidatesForTesting(memoryDirectory: dir)

        #expect(scored.contains { $0.filename == "2026-07-09.md" && $0.source == .daily && $0.signal > 0 })
        #expect(!scored.contains { $0.filename == "topic_only.md" })
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
                hits: [MemorySearchHit(filename: dailyFilename, score: 10.0, snippet: snippet)]
            )
        }
    }

    @Test("deep skips when daily deleted before promote")
    func deepRehydrateSkip() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens original"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["q1", "q2"],
            calendar: calendar,
            now: fixedNow
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        let candidates = try await scheduler.stageCandidatesForTesting(memoryDirectory: dir)
        #expect(candidates.contains { $0.recallCount >= 2 })

        try FileManager.default.removeItem(at: store.dailyURL(for: fixedNow, calendar: calendar))
        try await scheduler.promoteCandidatesForTesting(memoryDirectory: dir, candidates: candidates)
        let indexAfterDelete = (try? String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(indexAfterDelete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(store.listTopicFilenames().isEmpty)
    }

    @Test("deep skips when staged snippet no longer present in daily")
    func deepStaleSnippetSkip() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        let note = "rich distinctive conceptual tokens original"
        try store.appendDailyNote(note, date: fixedNow, calendar: calendar, now: fixedNow)
        try seedDailyRecalls(
            memoryDirectory: dir,
            dailyFilename: "2026-07-09.md",
            snippet: note,
            queries: ["q1", "q2"],
            calendar: calendar,
            now: fixedNow
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        let candidates = try await scheduler.stageCandidatesForTesting(memoryDirectory: dir)
        #expect(!candidates.isEmpty)

        let url = store.dailyURL(for: fixedNow, calendar: calendar)
        try MemoryFileLock.atomicWrite(text: "# Daily notes\n\nreplaced content only\n", to: url)
        try await scheduler.promoteCandidatesForTesting(memoryDirectory: dir, candidates: candidates)
        let index = (try? String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("unsearched daily does not promote under default threshold gates")
    func unsearchedDailyBlockedByDefaultGates() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.appendDailyNote(
            "rich distinctive conceptual tokens grafana dashboard pipeline",
            date: fixedNow,
            calendar: calendar,
            now: fixedNow
        )

        try await DreamingConsolidationScheduler(
            config: .default,
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        let index = (try? String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(store.listTopicFilenames().isEmpty)
    }

    @Test("daily below minRecallCount / minUniqueQueries does not promote")
    func belowRecallGatesBlocked() async throws {
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

        let index = (try? String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("deep promotes daily into curated topic + MEMORY.md index line")
    func deepPromotesToTopic() async throws {
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

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0
        config.dreamingMinRecallCount = 2
        config.dreamingMinUniqueQueries = 2
        try await DreamingConsolidationScheduler(
            config: config,
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        let index = try String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(!index.contains("2026-07-09.md"))
        #expect(index.contains("reference_2026-07-09_"))
        let topics = store.listTopicFilenames()
        #expect(topics.contains { $0.hasPrefix("reference_2026-07-09_") })
        let topicBody = try #require(try store.readTopicBody(filename: topics.first { $0.hasPrefix("reference_") }!))
        #expect(topicBody.contains(note) || topicBody.contains("grafana"))
    }

    @Test("default dreamingMinScore is 0.75; dreamingEnabled ships off")
    func defaultMinScore() {
        #expect(MemoryConfiguration.default.dreamingMinScore == 0.75)
        #expect(MemoryConfiguration.default.dreamingMinRecallCount == 2)
        #expect(MemoryConfiguration.default.dreamingMinUniqueQueries == 2)
        #expect(MemoryConfiguration.default.dreamingEnabled == false)
    }

    @Test("loader applies dreamingEnabled from memory object")
    func loaderDreamingEnabled() {
        let on = MemoryConfigurationLoader.load(fromMemoryObject: ["dreamingEnabled": true])
        #expect(on.dreamingEnabled == true)
        let off = MemoryConfigurationLoader.load(fromMemoryObject: ["dreamingEnabled": false])
        #expect(off.dreamingEnabled == false)
        let missing = MemoryConfigurationLoader.load(fromMemoryObject: [:])
        #expect(missing.dreamingEnabled == false)
    }

    @Test("extraction prompt includes daily capture guidance; flush prompt does not")
    func extractionIncludesDailyGuidanceFlushDoesNot() {
        let extraction = MemoryExtractionPrompts.systemPrompt(manifestLines: [])
        #expect(extraction.contains("YYYY-MM-DD.md"))
        #expect(extraction.contains("Capture vs curate"))
        let flush = MemoryPreCompactionFlushPrompts.systemPrompt(manifestLines: [])
        #expect(!flush.contains("Capture vs curate"))
        #expect(!flush.contains("Prefer appending durable-but-not-yet-curated"))
        #expect(flush.contains("Do NOT write daily staging"))
        #expect(flush.contains("curated promotion only"))
        #expect(flush.contains("## Non-negotiable flush constraints"))
        #expect(flush.contains("two steps"))
        #expect(flush.contains("Append-only"))
    }
}
