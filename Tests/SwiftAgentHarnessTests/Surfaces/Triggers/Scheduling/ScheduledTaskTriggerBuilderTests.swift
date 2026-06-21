import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ScheduledTaskTriggerBuilder")
struct ScheduledTaskTriggerBuilderTests {
    @Test("cron trigger shape matches scheduler fire path")
    func cronTriggerShape() {
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 60_000),
            payloadKind: .agentTurn,
            payloadText: "wake up",
            recurring: true,
            trust: .userDeferred,
            conversationID: nil,
            title: "Morning check"
        )
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task, fireTimestampMs: 1_700_000_000_000)
        #expect(trigger.id == "\(task.id):1700000000000")
        #expect(trigger.source == .cron)
        #expect(trigger.payload == "wake up")
        #expect(trigger.routingMode == .isolated)
        #expect(trigger.enableTools == true)
        #expect(trigger.sourceMetadata["cronJobId"] == task.id)
    }

    @Test("threaded cron includes conversationID metadata")
    func threadedCron() {
        let conversationID = UUID().uuidString
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "follow up",
            recurring: false,
            conversationID: conversationID,
            routingMode: .threaded
        )
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task, fireTimestampMs: 99)
        #expect(trigger.routingMode == .threaded)
        #expect(trigger.sourceMetadata["conversationID"] == conversationID)
    }

    @Test("missed prefix applied to payload")
    func missedPrefix() {
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .systemEvent,
            payloadText: "ping",
            recurring: false
        )
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task, missed: true, fireTimestampMs: 1)
        #expect(trigger.payload == "[missed] ping")
        #expect(trigger.enableTools == false)
    }
}
