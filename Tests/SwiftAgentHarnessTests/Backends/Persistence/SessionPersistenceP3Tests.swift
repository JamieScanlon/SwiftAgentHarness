import EasyJSON
import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence P3 (artifacts, multi-agent, tasks/cron)")
struct SessionPersistenceP3Tests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "p3-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test func engineArtifactRoundTripAndEvict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p3-art-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "a",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)

        let key = "ctx-proj"
        let blob = Data("hello-artifact".utf8)
        try local.putEngineArtifact(conversationID: cid, key: key, data: blob)
        #expect(try local.getEngineArtifact(conversationID: cid, key: key) == blob)
        try local.evictEngineArtifacts(conversationID: cid, key: key)
        #expect(try local.getEngineArtifact(conversationID: cid, key: key) == nil)
    }

    @Test func engineArtifactRoundTripAfterHarnessCreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p3-router-art-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let local = try LocalHarnessSessionPersistence(root: root)
        manager.setHarnessSessionPersistenceOverride(local)
        let conversation = try manager.createConversation(
            with: makeModel(),
            userSystemPrompt: "s",
            topic: "L",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )
        let blob = Data([7, 8, 9])
        try local.putEngineArtifact(conversationID: conversation.id, key: "k", data: blob)
        #expect(try local.getEngineArtifact(conversationID: conversation.id, key: "k") == blob)
    }

    @Test func catalogListsAreScopedPerAgentId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p3-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = try LocalHarnessSessionPersistence(root: root, agentId: "alice")
        let bob = try LocalHarnessSessionPersistence(root: root, agentId: "bob")
        let a = UUID()
        let b = UUID()
        var recA = SessionCatalogRecord(
            id: a,
            topic: "A",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        recA.agentId = "alice"
        try alice.bootstrapEmptyConversation(recA)

        var recB = SessionCatalogRecord(
            id: b,
            topic: "B",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        recB.agentId = "bob"
        try bob.bootstrapEmptyConversation(recB)

        #expect(try alice.listCatalogConversations().map(\.id).contains(a))
        #expect(!(try alice.listCatalogConversations().map(\.id).contains(b)))
        #expect(try bob.listCatalogConversations().map(\.id).contains(b))
        #expect(!(try bob.listCatalogConversations().map(\.id).contains(a)))

        #expect(throws: SessionPersistenceError.self) {
            try bob.readTranscriptEntries(conversationID: a, request: .full)
        }

        // `cache/engine-artifacts` is root-scoped (not under `agents/<id>/`); catalog + JSONL transcripts are per-agent.
        let ap = Data("alice".utf8)
        try alice.putEngineArtifact(conversationID: a, key: "k", data: ap)
        #expect(try alice.getEngineArtifact(conversationID: a, key: "k") == ap)
        #expect(try bob.getEngineArtifact(conversationID: a, key: "k") == ap)
    }

    @Test func sessionsRecoveryIndexWrittenOnBootstrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p3-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root, agentId: "rex")
        let cid = UUID()
        var record = SessionCatalogRecord(
            id: cid,
            topic: "r",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.agentId = "rex"
        try local.bootstrapEmptyConversation(record)
        let url = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["agentId"] as? String == "rex")
        let ids = json?["conversationIds"] as? [String]
        #expect(ids?.contains(cid.uuidString) == true)
    }

    @Test func taskRunAppendTailDeliveredFlow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p3-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let job = "nightly"
        let p1 = Data("one".utf8)
        let r1 = try local.appendTaskRun(jobId: job, payload: p1, idempotencyKey: "idem-a")
        let r1b = try local.appendTaskRun(jobId: job, payload: p1, idempotencyKey: "idem-a")
        #expect(r1 == r1b)

        let tail = try local.tailTaskRuns(jobId: job, limit: 5)
        #expect(tail.count == 1)
        #expect(tail[0].payload == p1)

        let pending = try local.latestUndeliveredTaskRun(jobId: job)
        #expect(pending?.runId == r1)
        try local.markTaskRunDelivered(runId: r1)
        #expect(try local.latestUndeliveredTaskRun(jobId: job) == nil)

        let p2 = Data("two".utf8)
        _ = try local.appendTaskRun(jobId: job, payload: p2, idempotencyKey: nil)
        let tail2 = try local.tailTaskRuns(jobId: job, limit: 10)
        #expect(tail2.count == 2)
        #expect(tail2.last?.payload == p2)

        let cronURL = SessionPersistenceLayout.cronRunFileURL(root: root, jobId: job)
        #expect(FileManager.default.fileExists(atPath: cronURL.path))
    }
}
