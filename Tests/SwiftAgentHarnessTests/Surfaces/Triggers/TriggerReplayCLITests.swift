import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerReplayCLI")
struct TriggerReplayCLITests {
    @Test("webhook test exits successfully")
    func webhookTest() throws {
        let dir = try makeTempDir()
        let dataDir = dir.appendingPathComponent("trigger-config", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let route = WebhookRoute(name: "cli-route", secret: "s", promptTemplate: "Event: {name}")
        try JSONEncoder().encode([route]).write(to: dataDir.appendingPathComponent("webhook_subscriptions.json"))
        let code = TriggerReplayCLI.execute(arguments: [
            "host", "trigger", "webhook", "test", "cli-route",
            "--payload", #"{"name":"ping"}"#,
            "--data-directory", dataDir.path,
        ])
        #expect(code == 0)
    }

    @Test("webhook fire enqueue writes json and trust sidecar")
    func webhookFireEnqueue() throws {
        let dir = try makeTempDir()
        let dataDir = dir.appendingPathComponent("trigger-config", isDirectory: true)
        let eventsDir = dir.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let route = WebhookRoute(name: "fire-route", secret: "s", promptTemplate: "Body: {x}")
        try JSONEncoder().encode([route]).write(to: dataDir.appendingPathComponent("webhook_subscriptions.json"))
        let code = TriggerReplayCLI.execute(arguments: [
            "host", "trigger", "webhook", "fire", "fire-route",
            "--payload", #"{"x":"go"}"#,
            "--data-directory", dataDir.path,
            "--events-dir", eventsDir.path,
            "--json",
        ])
        #expect(code == 0)
        let files = try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("replay-") && $0.pathExtension == "json" })
        #expect(files.contains { $0.pathExtension == "trust" })
    }

    @Test("snapshot replay enqueues trigger file")
    func snapshotEnqueue() throws {
        let dir = try makeTempDir()
        let eventsDir = dir.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let snap = dir.appendingPathComponent("trigger.json")
        let trigger = HarnessTrigger(
            id: "cli-snap",
            source: .fileEvent,
            payload: "from snapshot",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        try JSONEncoder().encode(trigger).write(to: snap)
        let code = TriggerReplayCLI.execute(arguments: [
            "host", "trigger", "snapshot", "replay", snap.path,
            "--events-dir", eventsDir.path,
            "--json",
        ])
        #expect(code == 0)
        let files = try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("replay-") })
    }

    @Test("cron fire loads scheduled task and enqueues")
    func cronFireEnqueue() throws {
        let dir = try makeTempDir()
        let dataDir = dir.appendingPathComponent("trigger-config", isDirectory: true)
        let eventsDir = dir.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let task = ScheduledTask(
            id: "task-cli-1",
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 1000),
            payloadKind: .agentTurn,
            payloadText: "cron replay",
            recurring: true
        )
        let store = ScheduledTaskStore(fileURL: dataDir.appendingPathComponent("scheduled_tasks.json"))
        _ = try TriggerRegistrationTestSupport.register(task, into: store)
        let code = TriggerReplayCLI.execute(arguments: [
            "host", "trigger", "cron", "fire", "task-cli-1",
            "--data-directory", dataDir.path,
            "--events-dir", eventsDir.path,
            "--json",
        ])
        #expect(code == 0)
        let files = try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("replay-") })
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
