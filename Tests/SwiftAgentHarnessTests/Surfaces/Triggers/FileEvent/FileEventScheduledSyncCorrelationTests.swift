import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventScheduledSyncCorrelation")
struct FileEventScheduledSyncCorrelationTests {
    @Test("future one-shot copies payload correlation to scheduled task")
    func oneShotCorrelation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fe-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let taskFile = dir.appendingPathComponent("tasks.json")
        let store = ScheduledTaskStore(fileURL: taskFile)
        let sync = FileEventScheduledSync(
            eventsDirectory: dir,
            taskStore: store,
            logger: Logger(label: "test")
        )
        let eventURL = dir.appendingPathComponent("follow-up.json")
        let payload = FileEventPayload(
            type: .oneShot,
            text: "check status",
            at: "2099-01-01T00:00:00Z",
            rootId: "webhook-root",
            parentTriggerId: "webhook-parent",
            correlationId: "workflow-42"
        )
        let synced = try sync.syncFutureOneShot(at: eventURL, payload: payload)
        #expect(synced == true)
        let tasks = try store.load()
        #expect(tasks.count == 1)
        let correlation = try #require(tasks[0].correlation)
        #expect(correlation.rootId == "webhook-root")
        #expect(correlation.parentTriggerId == "webhook-parent")
        #expect(correlation.correlationId == "workflow-42")
    }

    @Test("fired task trigger carries scheduled correlation")
    func firedTriggerCarriesCorrelation() throws {
        let task = ScheduledTask(
            id: "task-1",
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "follow up",
            recurring: false,
            correlation: TriggerCorrelation(
                rootId: "webhook-root",
                parentTriggerId: "webhook-parent",
                correlationId: "workflow-42",
                followUpKind: "scheduled"
            )
        )
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task, fireTimestampMs: 123)
        #expect(trigger.correlation?.rootId == "webhook-root")
        #expect(trigger.correlation?.parentTriggerId == "webhook-parent")
        #expect(trigger.correlation?.correlationId == "workflow-42")
    }
}
