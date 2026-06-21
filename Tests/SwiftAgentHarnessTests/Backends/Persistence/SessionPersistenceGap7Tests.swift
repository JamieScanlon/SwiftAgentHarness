import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence Gap 7 (state_meta + tasks registry)")
struct SessionPersistenceGap7Tests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func encodeTask(_ record: SessionScheduledTaskDefinitionRecord) throws -> Data {
        try JSONEncoder().encode(record)
    }

    @Test func stateMetaRoundTripOnLocalSQLite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        try local.setStateMetaValue(key: "install.flag", value: "v2")
        #expect(try local.getStateMetaValue(key: "install.flag") == "v2")
        try local.setStateMetaValue(key: "install.flag", value: "v3")
        #expect(try local.getStateMetaValue(key: "install.flag") == "v3")
        #expect(try local.getStateMetaValue(key: "missing") == nil)
    }

    @Test func scheduledTaskUpsertAndListByAgentOnLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap7-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let a = SessionScheduledTaskDefinitionRecord(taskId: "t-a", agentId: "agent1", definitionJSON: "{\"cron\":\"0 * * * *\"}")
        let b = SessionScheduledTaskDefinitionRecord(taskId: "t-b", agentId: "agent2", definitionJSON: "{}")
        try local.upsertScheduledTaskDefinition(try encodeTask(a))
        try local.upsertScheduledTaskDefinition(try encodeTask(b))

        let all = try local.listScheduledTaskDefinitions(agentId: nil)
        #expect(all.count == 2)

        let agent1 = try local.listScheduledTaskDefinitions(agentId: "agent1")
        #expect(agent1.count == 1)
        let r1 = try JSONDecoder().decode(SessionScheduledTaskDefinitionRecord.self, from: agent1[0])
        #expect(r1.taskId == "t-a")

        let merged = SessionScheduledTaskDefinitionRecord(taskId: "t-a", agentId: "agent1", definitionJSON: "{\"cron\":\"updated\"}")
        try local.upsertScheduledTaskDefinition(try encodeTask(merged))
        let again = try local.listScheduledTaskDefinitions(agentId: "agent1")
        #expect(again.count == 1)
        let r2 = try JSONDecoder().decode(SessionScheduledTaskDefinitionRecord.self, from: again[0])
        #expect(r2.definitionJSON.contains("updated"))
    }

    @Test func scheduledTaskSurvivesCatalogReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap7-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rec = SessionScheduledTaskDefinitionRecord(taskId: "persist", agentId: nil, definitionJSON: "{}")
        do {
            let local = try LocalHarnessSessionPersistence(root: root)
            try local.upsertScheduledTaskDefinition(try encodeTask(rec))
            try local.setStateMetaValue(key: "x", value: "y")
        }
        let local2 = try LocalHarnessSessionPersistence(root: root)
        #expect(try local2.getStateMetaValue(key: "x") == "y")
        let rows = try local2.listScheduledTaskDefinitions(agentId: nil)
        #expect(rows.count == 1)
    }

    @Test func inMemoryParity() throws {
        let mem = InMemoryHarnessSessionPersistence(agentId: "default")
        try mem.setStateMetaValue(key: "a", value: "b")
        #expect(try mem.getStateMetaValue(key: "a") == "b")

        let t = SessionScheduledTaskDefinitionRecord(taskId: "m1", agentId: "default", definitionJSON: "[]")
        try mem.upsertScheduledTaskDefinition(try encodeTask(t))
        #expect(try mem.listScheduledTaskDefinitions(agentId: "default").count == 1)
        #expect(try mem.listScheduledTaskDefinitions(agentId: "other").isEmpty)
    }
}
