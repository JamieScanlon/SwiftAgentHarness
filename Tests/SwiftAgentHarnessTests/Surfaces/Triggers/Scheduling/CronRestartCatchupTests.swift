import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("CronRestartCatchup")
struct CronRestartCatchupTests {
    private actor DeliverRecorder {
        private(set) var triggers: [HarnessTrigger] = []
        func record(_ trigger: HarnessTrigger) { triggers.append(trigger) }
        var count: Int { triggers.count }
    }

    private actor MarkRecorder {
        private(set) var ids: [UUID] = []
        func add(_ id: UUID) { ids.append(id) }
        var isEmpty: Bool { ids.isEmpty }
    }

    private func makeStore() -> ScheduledTaskStore {
        ScheduledTaskStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("catchup-tasks-\(UUID().uuidString).json"))
    }

    private func ports(for backend: InMemoryHarnessSessionPersistence) -> TriggerTaskRunPorts {
        TriggerTaskRunPorts(
            append: { jobId, payload, key in try backend.appendTaskRun(jobId: jobId, payload: payload, idempotencyKey: key) },
            latestUndelivered: { jobId in try backend.latestUndeliveredTaskRun(jobId: jobId) },
            markDelivered: { runId in try backend.markTaskRunDelivered(runId: runId) }
        )
    }

    private func scheduler(
        store: ScheduledTaskStore,
        recorder: DeliverRecorder,
        taskRuns: TriggerTaskRunPorts
    ) -> TriggerSchedulerService {
        TriggerSchedulerService(
            store: store,
            deliver: { trigger in
                await recorder.record(trigger)
                return TriggerActivationResult(decision: .admitted, sessionID: nil)
            },
            lockURL: FileManager.default.temporaryDirectory.appendingPathComponent("catchup-lock-\(UUID().uuidString).json"),
            taskRuns: taskRuns,
            logger: Logger(label: "test.catchup")
        )
    }

    @Test("fire marks the run delivered (persists-delivered-status)")
    func persistsDeliveredStatus() async throws {
        let backend = InMemoryHarnessSessionPersistence()
        let store = makeStore()
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2020-01-01T00:00:00Z"),
            payloadKind: .systemEvent,
            payloadText: "ping",
            recurring: false
        )
        _ = try TriggerRegistrationTestSupport.register(task, into: store)
        let recorder = DeliverRecorder()
        let svc = scheduler(store: store, recorder: recorder, taskRuns: ports(for: backend))

        _ = try await svc.fireNow(id: task.id)

        #expect(await recorder.count == 1)
        #expect(try backend.latestUndeliveredTaskRun(jobId: task.id) == nil)
    }

    @Test("restart catch-up re-delivers an undelivered run exactly once")
    func restartCatchup() async throws {
        let backend = InMemoryHarnessSessionPersistence()
        let store = makeStore()
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2020-01-01T00:00:00Z"),
            payloadKind: .systemEvent,
            payloadText: "ping",
            recurring: false
        )
        _ = try TriggerRegistrationTestSupport.register(task, into: store)
        _ = try backend.appendTaskRun(jobId: task.id, payload: Data("ping".utf8), idempotencyKey: "\(task.id):0")

        let recorder = DeliverRecorder()
        let svc = scheduler(store: store, recorder: recorder, taskRuns: ports(for: backend))

        await svc.catchUp()
        #expect(await recorder.count == 1)
        #expect(try backend.latestUndeliveredTaskRun(jobId: task.id) == nil)

        await svc.catchUp()
        #expect(await recorder.count == 1)
    }

    @Test("recurring job does not replay a missed run outside the current window")
    func recurringNoReplay() async throws {
        let store = makeStore()
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 60_000),
            payloadKind: .systemEvent,
            payloadText: "tick",
            recurring: true
        )
        _ = try TriggerRegistrationTestSupport.register(task, into: store)

        let staleRunId = UUID()
        let stale = SessionHarnessTaskRunRecord(
            runId: staleRunId,
            jobId: task.id,
            createdAt: Date().addingTimeInterval(-3600),
            payload: Data("tick".utf8),
            idempotencyKey: nil
        )
        let marked = MarkRecorder()
        let taskRuns = TriggerTaskRunPorts(
            append: { _, _, _ in UUID() },
            latestUndelivered: { _ in stale },
            markDelivered: { await marked.add($0) }
        )
        let recorder = DeliverRecorder()
        let svc = scheduler(store: store, recorder: recorder, taskRuns: taskRuns)

        await svc.catchUp()

        #expect(await recorder.count == 0)
        #expect(await marked.isEmpty)
    }

    @Test("appendTaskRun with the same window key is idempotent")
    func idempotentWindowKey() throws {
        let backend = InMemoryHarnessSessionPersistence()
        let id1 = try backend.appendTaskRun(jobId: "job", payload: Data("p".utf8), idempotencyKey: "job:100")
        let id2 = try backend.appendTaskRun(jobId: "job", payload: Data("p".utf8), idempotencyKey: "job:100")
        #expect(id1 == id2)
    }

    @Test("CronRunWindow honors per-kind semantics")
    func windowSemantics() {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 18
        components.hour = 12
        components.minute = 2
        components.second = 30
        let now = Calendar.current.date(from: components)!
        let recent = SessionHarnessTaskRunRecord(runId: UUID(), jobId: "j", createdAt: now.addingTimeInterval(-10), payload: Data(), idempotencyKey: nil)
        let stale = SessionHarnessTaskRunRecord(runId: UUID(), jobId: "j", createdAt: now.addingTimeInterval(-3600), payload: Data(), idempotencyKey: nil)

        let oneShot = ScheduledTask(schedule: ScheduledTaskSchedule(kind: .at, at: "2020-01-01T00:00:00Z"), payloadKind: .systemEvent, payloadText: "next-fire math", recurring: false)
        #expect(CronRunWindow.contains(record: stale, task: oneShot, now: now) == true)

        let every = ScheduledTask(schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 60_000), payloadKind: .systemEvent, payloadText: "next-fire math", recurring: true)
        #expect(CronRunWindow.contains(record: recent, task: every, now: now) == true)
        #expect(CronRunWindow.contains(record: stale, task: every, now: now) == false)

        let cron = ScheduledTask(schedule: ScheduledTaskSchedule(kind: .cron, expr: "*/5 * * * *"), payloadKind: .systemEvent, payloadText: "next-fire math", recurring: true)
        #expect(CronRunWindow.contains(record: recent, task: cron, now: now) == true)
        #expect(CronRunWindow.contains(record: stale, task: cron, now: now) == false)
    }
}
