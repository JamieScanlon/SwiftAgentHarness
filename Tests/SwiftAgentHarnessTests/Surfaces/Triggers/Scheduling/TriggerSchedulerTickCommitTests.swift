import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerScheduler tick commit")
struct TriggerSchedulerTickCommitTests {
    @Test("unauthorized delivery does not delete a due one-shot")
    func unauthorizedDoesNotConsumeOneShot() async throws {
        let harness = try makeHarness(deliver: { _ in
            TriggerActivationResult(decision: .unauthorized, sessionID: nil)
        })
        let task = pastOneShot(id: "oneshot-unauth")
        _ = try TriggerRegistrationTestSupport.register(task, into: harness.store)

        await harness.scheduler.tick()

        let remaining = try harness.store.load()
        #expect(remaining.map(\.id) == ["oneshot-unauth"])
        #expect(remaining.first?.lastFiredAt == nil)
    }

    @Test("admitted delivery deletes a due one-shot")
    func admittedConsumesOneShot() async throws {
        let harness = try makeHarness(deliver: { _ in
            TriggerActivationResult(decision: .admitted, sessionID: UUID())
        })
        let task = pastOneShot(id: "oneshot-admit")
        _ = try TriggerRegistrationTestSupport.register(task, into: harness.store)

        await harness.scheduler.tick()

        #expect(try harness.store.load().isEmpty)
    }

    @Test("unauthorized delivery does not stamp lastFiredAt on a recurring task")
    func unauthorizedDoesNotStampLastFiredAt() async throws {
        let harness = try makeHarness(deliver: { _ in
            TriggerActivationResult(decision: .unauthorized, sessionID: nil)
        })
        let task = dueEvery(id: "every-unauth")
        _ = try TriggerRegistrationTestSupport.register(task, into: harness.store)

        await harness.scheduler.tick()

        let remaining = try #require(try harness.store.load().first)
        #expect(remaining.id == "every-unauth")
        #expect(remaining.lastFiredAt == nil)
    }

    @Test("admitted delivery stamps lastFiredAt on a recurring task")
    func admittedStampsLastFiredAt() async throws {
        let harness = try makeHarness(deliver: { _ in
            TriggerActivationResult(decision: .admitted, sessionID: UUID())
        })
        let task = dueEvery(id: "every-admit")
        _ = try TriggerRegistrationTestSupport.register(task, into: harness.store)

        await harness.scheduler.tick()

        let remaining = try #require(try harness.store.load().first)
        #expect(remaining.id == "every-admit")
        #expect(remaining.lastFiredAt != nil)
    }

    private struct Harness {
        let store: ScheduledTaskStore
        let scheduler: TriggerSchedulerService
    }

    private func makeHarness(
        deliver: @escaping @Sendable (HarnessTrigger) async throws -> TriggerActivationResult
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let scheduler = TriggerSchedulerService(
            store: store,
            deliver: deliver,
            lockURL: directory.appendingPathComponent("scheduler.lock"),
            logger: Logger(label: "test.tick-commit")
        )
        return Harness(store: store, scheduler: scheduler)
    }

    private func pastOneShot(id: String) -> ScheduledTask {
        ScheduledTask(
            id: id,
            schedule: ScheduledTaskSchedule(kind: .at, at: "2020-01-01T00:00:00Z"),
            payloadKind: .systemEvent,
            payloadText: "ping",
            recurring: false
        )
    }

    private func dueEvery(id: String) -> ScheduledTask {
        ScheduledTask(
            id: id,
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 60_000),
            payloadKind: .systemEvent,
            payloadText: "tick",
            recurring: true
        )
    }
}
