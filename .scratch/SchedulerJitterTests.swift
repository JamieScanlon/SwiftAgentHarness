import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Scheduler fire-time jitter")
struct SchedulerJitterTests {
    private func makeScheduler() -> TriggerSchedulerService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jitter-\(UUID().uuidString)")
        return TriggerSchedulerService(
            store: ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json")),
            deliver: { _ in TriggerActivationResult(decision: .admitted, sessionID: nil) },
            lockURL: directory.appendingPathComponent("scheduler.lock"),
            logger: Logger(label: "test")
        )
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    private func cronTask(expr: String, lastFiredAt: Date?, createdAt: Date) -> ScheduledTask {
        ScheduledTask(
            id: "jitter-\(UUID().uuidString)",
            createdAt: Int64(createdAt.timeIntervalSince1970 * 1000),
            lastFiredAt: lastFiredAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .agentTurn,
            payloadText: "x",
            recurring: true,
            timezone: "UTC"
        )
    }

    /// The bug: `jittered` re-rolls on every call, and `tick()` fires whenever `fireAt <= now`. With
    /// a symmetric offset, any tick in the seconds *before* a boundary could roll a fire time at or
    /// below `now` and fire early — then the next tick, still before the boundary, could do it again.
    /// Nothing deduped it, because the idempotency key is keyed on `lastFiredAt`, which had just
    /// changed.
    ///
    /// Sampled rather than asserted once, because the offset is random: a single call passes ~50% of
    /// the time even with the bug present.
    @Test("a fire is never scheduled before its boundary")
    func neverFiresEarly() async throws {
        let scheduler = makeScheduler()
        let boundary = try date("2026-06-01T09:00:00Z")
        let created = try date("2026-06-01T00:00:00Z")
        // A tick inside the old negative-jitter window: 3s before the boundary, where `nextDate`
        // still returns this boundary.
        let now = boundary.addingTimeInterval(-3)

        for _ in 0 ..< 200 {
            let task = cronTask(expr: "0 9 * * *", lastFiredAt: created, createdAt: created)
            let fireAt = try #require(await scheduler.nextFireDate(for: task, now: now))
            #expect(fireAt >= boundary, "a job scheduled for 09:00:00 must not run at \(fireAt)")
            #expect(fireAt > now, "and therefore must not fire on this tick")
        }
    }

    /// Jitter still spreads load — it just only ever delays. Without this the fix could have been
    /// "delete the jitter", which would have every task in a deployment fire on the same second.
    @Test("jitter still spreads fires after the boundary")
    func stillJitters() async throws {
        let scheduler = makeScheduler()
        let boundary = try date("2026-06-01T09:00:00Z")
        let created = try date("2026-06-01T00:00:00Z")
        let now = boundary.addingTimeInterval(-30)

        var offsets = Set<Double>()
        for _ in 0 ..< 200 {
            let task = cronTask(expr: "0 9 * * *", lastFiredAt: created, createdAt: created)
            let fireAt = try #require(await scheduler.nextFireDate(for: task, now: now))
            offsets.insert((fireAt.timeIntervalSince(boundary) * 1000).rounded())
        }
        #expect(offsets.count > 1, "every fire landing on the same instant would defeat the purpose")
        #expect(offsets.allSatisfy { $0 >= 0 })
        // Cron uses a 60s nominal interval, so the span is min(60 * 0.10, 60) = 6 seconds.
        #expect(offsets.allSatisfy { $0 <= 6000 })
    }

    /// The consequence that makes the double fire impossible rather than merely unlikely: once a
    /// fire lands at or after its boundary, the next computation necessarily returns the *following*
    /// boundary.
    @Test("after firing at a boundary the next fire is the following boundary")
    func advancesPastFiredBoundary() async throws {
        let scheduler = makeScheduler()
        let boundary = try date("2026-06-01T09:00:00Z")
        let created = try date("2026-06-01T00:00:00Z")
        // Fired 2s after the boundary, and the next tick is 3s after it.
        let task = cronTask(
            expr: "0 9 * * *",
            lastFiredAt: boundary.addingTimeInterval(2),
            createdAt: created
        )
        let next = try #require(
            await scheduler.nextFireDate(for: task, now: boundary.addingTimeInterval(3))
        )
        #expect(next >= try date("2026-06-02T09:00:00Z"), "must be tomorrow's 09:00, not today's again")
    }

    /// `at` one-shots must not run early either — "remind me at 3pm" firing at 14:59:56 is the same
    /// defect in a form the user notices more.
    @Test("a one-shot never fires before its stated time")
    func oneShotNeverEarly() async throws {
        let scheduler = makeScheduler()
        let target = try date("2026-06-01T15:00:00Z")
        for _ in 0 ..< 100 {
            let task = ScheduledTask(
                id: "at-\(UUID().uuidString)",
                schedule: ScheduledTaskSchedule(kind: .at, at: "2026-06-01T15:00:00Z"),
                payloadKind: .agentTurn,
                payloadText: "x",
                recurring: false
            )
            let fireAt = try #require(await scheduler.nextFireDate(for: task, now: target.addingTimeInterval(-10)))
            #expect(fireAt >= target)
        }
    }
}
