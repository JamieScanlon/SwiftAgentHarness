import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventPeriodicSync")
struct FileEventPeriodicSyncTests {
    @Test("upserts scheduled task from periodic file")
    func upsertPeriodic() throws {
        let dir = try makeTempDir()
        let storeURL = dir.appendingPathComponent("tasks.json")
        let event = dir.appendingPathComponent("daily.json")
        try JSONEncoder().encode(FileEventPayload(type: .periodic, text: "check inbox", schedule: "0 9 * * *")).write(to: event)
        let store = ScheduledTaskStore(fileURL: storeURL)
        let sync = FileEventPeriodicSync(
            eventsDirectory: dir,
            registration: TriggerRegistrationTestSupport.service(store: store),
            logger: Logger(label: "test")
        )
        try sync.syncFromFile(at: event)
        let tasks = try store.load()
        #expect(tasks.count == 1)
        #expect(tasks[0].id == "file-periodic:daily")
        #expect(tasks[0].schedule.expr == "0 9 * * *")
    }

    @Test("deletes scheduled task when periodic file removed")
    func deletePeriodic() throws {
        let dir = try makeTempDir()
        let storeURL = dir.appendingPathComponent("tasks.json")
        let store = ScheduledTaskStore(fileURL: storeURL)
        let sync = FileEventPeriodicSync(
            eventsDirectory: dir,
            registration: TriggerRegistrationTestSupport.service(store: store),
            logger: Logger(label: "test")
        )
        _ = try TriggerRegistrationTestSupport.register(
            ScheduledTask(
                id: "file-periodic:daily",
                schedule: ScheduledTaskSchedule(kind: .cron, expr: "0 9 * * *"),
                payloadKind: .agentTurn,
                payloadText: "x",
                recurring: true
            ),
            into: store,
            authority: .localFileDrop()
        )
        try sync.removeForDeletedFile(named: "daily.json")
        #expect(try store.load().isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-periodic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
