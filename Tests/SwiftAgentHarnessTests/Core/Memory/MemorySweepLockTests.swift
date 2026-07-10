import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Memory sweep lock")
struct MemorySweepLockTests {
    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dream-c8-\(UUID().uuidString)", isDirectory: true)
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

    @Test("deep promote under sweep lock completes without nested-lock deadlock")
    func deepPromoteNoDeadlock() async throws {
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

        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(index.contains("reference_2026-07-09_"))
        #expect(try DreamSweepReportStore(memoryDirectory: dir).read() != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("DREAMS.md").path))
    }

    @Test("concurrent sweep and locked index writers leave well-formed MEMORY.md")
    func concurrentSweepAndIndexWriters() async throws {
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

        let injected = "- [Injected](injected_topic.md) — concurrent writer line"
        async let sweep: Void = DreamingConsolidationScheduler(
            config: openGatesConfig(),
            calendar: calendar,
            now: { fixedNow }
        ).runSweep(memoryDirectory: dir)

        async let writer: Void = {
            for i in 0..<20 {
                _ = try? store.writeIndex(content: "\(injected) #\(i)\n")
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }()

        _ = await (try sweep, writer)

        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(!index.contains("\u{0}"))
        let hasPromote = index.contains("reference_2026-07-09_")
        let hasInjected = index.contains("Injected")
        #expect(hasPromote || hasInjected)
        // UTF-8 round-trip succeeded; content is a complete write from one side or the other.
        #expect(!index.isEmpty || hasPromote || hasInjected)
    }

    @Test("memory-dir write waits on held .memory.lock then completes")
    func toolPathSharesLock() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("MEMORY.md")
        try MemoryFileLock.atomicWrite(text: "base\n", to: target)

        let started = expectationGate()
        let hold = expectationGate()
        let finished = expectationGate()

        Task.detached {
            try? MemoryFileLock.withLock(memoryDirectory: dir) {
                started.signal()
                hold.wait()
                // Keep holding briefly so the async writer must wait.
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        started.wait()
        async let writeDone: Void = MemoryFileLock.withLockAsync(memoryDirectory: dir) {
            try MemoryFileLock.atomicWrite(text: "from-async\n", to: target)
            finished.signal()
        }
        // Writer should not finish while we still hold the lock.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!finished.isSignaled)
        hold.signal()
        try await writeDone
        finished.wait()
        let body = try String(contentsOf: target, encoding: .utf8)
        #expect(body == "from-async\n")
    }

    @Test("assuming-locked APIs work under outer withLock")
    func assumingLockedUnderOuter() throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentMemoryStore(memoryDirectory: dir)
        try MemoryFileLock.withLock(memoryDirectory: dir) {
            try store.writeTopicAssumingLocked(
                filename: "reference_lock.md",
                content: """
                ---
                name: Lock
                description: test
                type: reference
                ---
                body
                """
            )
            _ = try store.writeIndexAssumingLocked(content: "- [Lock](reference_lock.md) — test\n")
            let ledger = DreamPromotionLedger(memoryDirectory: dir)
            try ledger.writeLastDeepMarkerAssumingLocked(
                DreamLastDeepMarker(runID: "r1", promoted: ["reference_lock.md"], sourceDailies: [])
            )
            let reportStore = DreamSweepReportStore(memoryDirectory: dir)
            let report = DreamSweepReport(
                runID: "r1",
                completedAt: "2026-07-09T00:00:00Z",
                thresholds: DreamThresholdSnapshot(minScore: 0.75, minRecallCount: 2, minUniqueQueries: 2),
                light: [],
                rem: [],
                deepPromoted: [],
                deepRejected: []
            )
            try reportStore.writeAssumingLocked(report)
            try reportStore.appendDiaryAssumingLocked(for: report)
        }
        #expect(try store.readTopicBody(filename: "reference_lock.md") != nil)
        #expect(DreamPromotionLedger(memoryDirectory: dir).readLastDeepMarker()?.runID == "r1")
        #expect(try DreamSweepReportStore(memoryDirectory: dir).read()?.runID == "r1")
    }
}

/// Tiny cross-thread gate for lock-ordering tests (not XCTestExpectation).
private final class ExpectationGate: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.lock()
        signaled = true
        lock.unlock()
        sem.signal()
    }

    func wait() {
        sem.wait()
    }

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

private func expectationGate() -> ExpectationGate { ExpectationGate() }
