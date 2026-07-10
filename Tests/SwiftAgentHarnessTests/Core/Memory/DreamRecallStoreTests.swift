import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Dream recall store")
struct DreamRecallStoreTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-recall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTopic(dir: URL, filename: String, body: String) throws {
        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.writeTopic(
            filename: filename,
            content: """
            ---
            name: \(filename)
            description: \(body)
            type: reference
            ---
            \(body)
            """
        )
    }

    @Test("memory_search appends recall entries with query hash, day, and scores")
    func searchAppendsEntries() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "reference_grafana.md", body: "grafana metrics dashboard")

        let provider = MemorySearchToolProvider(memoryDirectory: dir, search: HybridMemorySearch())
        let result = try await provider.executeTool(
            ToolCall(
                name: MemorySearchToolProvider.searchToolName,
                arguments: .object(["query": .string("grafana metrics")]),
                id: "search-1"
            )
        )
        #expect(result.success)

        let store = DreamRecallStore(memoryDirectory: dir)
        let entries = try store.loadEntries()
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.source == .memorySearch })
        #expect(entries.contains { $0.filename == "reference_grafana.md" })
        let expectedHash = DreamRecallStore.queryHash(for: "grafana metrics")
        #expect(entries.allSatisfy { $0.queryHash == expectedHash })
        #expect(entries.allSatisfy { !$0.recallDay.isEmpty })
        #expect(entries.contains { $0.score > 0 })
    }

    @Test("memory_get appends a recall entry")
    func getAppendsEntry() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "user_role.md", body: "user is a platform engineer")

        let provider = MemorySearchToolProvider(memoryDirectory: dir, search: HybridMemorySearch())
        let result = try await provider.executeTool(
            ToolCall(
                name: MemorySearchToolProvider.getToolName,
                arguments: .object(["filename": .string("user_role.md")]),
                id: "get-1"
            )
        )
        #expect(result.success)

        let entries = try DreamRecallStore(memoryDirectory: dir).loadEntries()
        #expect(entries.count == 1)
        #expect(entries[0].filename == "user_role.md")
        #expect(entries[0].source == .memoryGet)
        #expect(entries[0].score == 1.0)
        #expect(entries[0].queryHash == DreamRecallStore.getQueryHash(filename: "user_role.md"))
    }

    @Test("concurrent appends do not corrupt JSONL")
    func concurrentAppendsRemainValid() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DreamRecallStore(memoryDirectory: dir)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try store.recordGet(
                        filename: "topic\(i % 3).md",
                        snippet: "snippet \(i)"
                    )
                }
            }
            try await group.waitForAll()
        }

        let entries = try store.loadEntries()
        #expect(entries.count == 20)
        #expect(entries.allSatisfy { !$0.filename.isEmpty })
    }

    @Test("light scores differ across files given different recall signals")
    func lightScoresReflectSignals() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!

        let store = DreamRecallStore(memoryDirectory: dir, calendar: calendar, now: { fixedNow })
        // Hot file: many recalls, diverse queries, high scores, recent
        for q in ["alpha one", "alpha two", "alpha three", "alpha four"] {
            try store.recordSearchHits(
                query: q,
                hits: [MemorySearchHit(filename: "hot.md", score: 8.0, snippet: "rich unique tokens dashboard metrics pipeline")]
            )
        }
        // Cold file: single low-score recall with a backdated day via direct append path
        // Use search with one query then overwrite day by constructing entry through recordGet + additional searches
        try store.recordSearchHits(
            query: "only once",
            hits: [MemorySearchHit(filename: "cold.md", score: 1.0, snippet: "plain note")]
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0.0
        config.dreamingMinRecallCount = 1
        config.dreamingMinUniqueQueries = 1
        let scheduler = DreamingConsolidationScheduler(config: config, calendar: calendar, now: { fixedNow })
        let scored = try await scheduler.stageCandidatesForTesting(memoryDirectory: dir)
        let hot = scored.first { $0.filename == "hot.md" }
        let cold = scored.first { $0.filename == "cold.md" }
        #expect(hot != nil)
        #expect(cold != nil)
        #expect((hot?.signal ?? 0) > (cold?.signal ?? 1))
    }

    @Test("deep respects minRecallCount and minUniqueQueries gates")
    func deepRespectsGates() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "gated.md", body: "gated topic content")

        let store = DreamRecallStore(memoryDirectory: dir)
        // One recall, one unique query — below gates
        try store.recordSearchHits(
            query: "once",
            hits: [MemorySearchHit(filename: "gated.md", score: 10.0, snippet: "rich distinctive conceptual tokens here")]
        )

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0.0
        config.dreamingMinRecallCount = 3
        config.dreamingMinUniqueQueries = 2
        let scheduler = DreamingConsolidationScheduler(config: config)
        try await scheduler.runSweep(memoryDirectory: dir)

        let index = (try? String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        #expect(!index.contains("gated.md"))

        // Satisfy gates
        try store.recordSearchHits(
            query: "second",
            hits: [MemorySearchHit(filename: "gated.md", score: 10.0, snippet: "rich distinctive conceptual tokens here")]
        )
        try store.recordSearchHits(
            query: "third",
            hits: [MemorySearchHit(filename: "gated.md", score: 10.0, snippet: "rich distinctive conceptual tokens here")]
        )
        try await scheduler.runSweep(memoryDirectory: dir)
        let promoted = try String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(promoted.contains("gated.md"))
    }

    @Test("empty recall store does not promote from bare topic manifest")
    func emptyStorePromotesNothing() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "orphan.md", body: "never recalled")

        var config = MemoryConfiguration.default
        config.dreamingMinScore = 0.0
        config.dreamingMinRecallCount = 1
        config.dreamingMinUniqueQueries = 1
        try await DreamingConsolidationScheduler(config: config).runSweep(memoryDirectory: dir)

        let indexExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("MEMORY.md").path)
        if indexExists {
            let index = try String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
            #expect(!index.contains("orphan.md"))
        }
    }

    @Test("query hash normalizes whitespace and case")
    func queryHashNormalizes() {
        let a = DreamRecallStore.queryHash(for: "Grafana  Metrics")
        let b = DreamRecallStore.queryHash(for: "grafana metrics")
        #expect(a == b)
    }
}
