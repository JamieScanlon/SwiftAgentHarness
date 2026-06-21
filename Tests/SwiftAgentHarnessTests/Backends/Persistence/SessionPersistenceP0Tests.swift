import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence P0 (JSONL truth, parent chain, lock)")
struct SessionPersistenceP0Tests {

    @Test func localAppendRoundTripParentAndJSONLAuthoritative() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)

        let m1 = Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let e1 = try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: e1)

        let m2 = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let e2 = try SessionTranscriptMapping.entry(from: m2, sequence: 2, parentEntryId: SessionEntryID.fromMessageUUID(m1.id))
        try local.appendTranscriptEntry(conversationID: cid, entry: e2)

        let read = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.count == 2)
        #expect(read[0].entryId == SessionEntryID.fromMessageUUID(m1.id))
        #expect(read[0].parentEntryId == nil)
        #expect(read[1].entryId == SessionEntryID.fromMessageUUID(m2.id))
        #expect(read[1].parentEntryId == SessionEntryID.fromMessageUUID(m1.id))

        let jsonlURL = SessionPersistenceLayout.transcriptURL(root: root, agentId: SessionPersistenceLayout.defaultAgentId, conversationId: cid)
        let rawLines = try String(contentsOf: jsonlURL, encoding: .utf8).split(separator: "\n").filter { !$0.isEmpty }
        #expect(rawLines.count == 3)
    }

    @Test func acquireTranscriptWriteLockIsProcessAwareType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: nil,
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)

        let lock = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false)
        #expect(lock.conversationID == cid)
        lock.unlock()
    }

    @Test("readTranscriptEntries and activeMessages fall back to catalog when JSONL is missing")
    func catalogTranscriptFallbackWhenJSONLMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-catalog-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Fitness")
        let user = Message(id: UUID(), role: .user, content: "Plan the app", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)

        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try FileManager.default.removeItem(at: jsonlURL)

        let read = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.contains { $0.type == .message })

        let messages = try ConversationTranscriptLineage.activeMessages(conversationID: cid, harness: local)
        #expect(messages.contains { $0.role == .user && $0.content == "Plan the app" })
    }

    @Test("readTranscriptEntries falls back to catalog when JSONL header is corrupt")
    func catalogTranscriptFallbackWhenJSONLCorrupt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-catalog-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Corrupt")
        let user = Message(id: UUID(), role: .user, content: "Still readable", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)

        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try "not a transcript".write(to: jsonlURL, atomically: true, encoding: .utf8)

        let read = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.contains { $0.type == .message })

        let messages = try ConversationTranscriptLineage.activeMessages(conversationID: cid, harness: local)
        #expect(messages.contains { $0.role == .user && $0.content == "Still readable" })
    }

    @Test("readTranscriptEntries reconcile does not advance conversations.updated_at")
    func reconcilePreservesConversationUpdatedAt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-reconcile-ts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Ts")
        let user = Message(
            id: UUID(),
            role: .user,
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            toolCalls: []
        )
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)

        let before = try #require(try local.catalogConversation(id: cid))
        try local.reconcileTranscriptCatalogFromJSONL(conversationID: cid)
        let after = try #require(try local.catalogConversation(id: cid))
        #expect(after.updatedAt == before.updatedAt)
    }

    @Test("transcriptEntry and readLineage read catalog when JSONL is missing")
    func catalogOnlyHotPathsWhenJSONLMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-catalog-hot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Hot")
        let user = Message(id: UUID(), role: .user, content: "catalog only", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)
        let entryId = SessionEntryID.fromMessageUUID(user.id)

        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try FileManager.default.removeItem(at: jsonlURL)

        let entry = try local.transcriptEntry(conversationID: cid, entryId: entryId)
        #expect(entry.entryId == entryId)
        let lineage = try local.readLineage(conversationID: cid, leafEntryId: entryId)
        #expect(lineage.count == 1)
        #expect(lineage[0].entryId == entryId)
    }

    @Test("JSONL reader skips corrupt body lines and keeps valid entries")
    func jsonlReaderSkipsCorruptBodyLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-jsonl-lenient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Lenient")
        let user = Message(id: UUID(), role: .user, content: "Kept row", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)

        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        var text = try String(contentsOf: jsonlURL, encoding: .utf8)
        text += "\n{\"sequence\":999,\"id\":\"bad\",\"type\":\"message\",\"timestamp\":\"not-a-date\",\"payloadJSON\":\"{}\"}\n"
        try text.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let read = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.contains { $0.type == .message })
        #expect(read.allSatisfy { $0.sequence != 999 })
    }

    @Test("readTranscriptEntries throws transcriptCorrupt when JSONL is unparseable and catalog is empty")
    func transcriptCorruptWhenJSONLUnparseableAndCatalogEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-corrupt-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "Empty",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )
        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try "not a transcript".write(to: jsonlURL, atomically: true, encoding: .utf8)

        #expect(throws: SessionPersistenceError.self) {
            try local.readTranscriptEntries(conversationID: cid, request: .full)
        }
    }

    @Test("repairTranscriptFromCatalog restores readable JSONL under lock")
    func repairTranscriptFromCatalogRewritesJSONL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Repair")
        let user = Message(id: UUID(), role: .user, content: "restore me", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)

        let jsonlURL = local.transcriptFileURL(conversationID: cid)
        try "truncated garbage".write(to: jsonlURL, atomically: true, encoding: .utf8)

        let readBeforeRepair = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(readBeforeRepair.contains { $0.type == .message })

        try local.repairTranscriptFromCatalog(conversationID: cid)
        let repaired = try SessionJSONLTranscriptReader.loadEntries(fileURL: jsonlURL)
        #expect(repaired.contains { $0.type == .message })
    }

    @Test("quarantined transcript serves catalog and blocks append")
    func quarantinedTranscriptServesCatalogAndBlocksAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p0-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try HarnessConversationTestFixtures.bootstrapEmptySession(local: local, id: cid, model: HarnessConversationTestFixtures.makeTestModel(), topic: "Q")
        let user = Message(id: UUID(), role: .user, content: "still here", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: user)
        try local.quarantineTranscript(conversationID: cid, reason: "test")

        let read = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.contains { $0.type == .message })

        let blocked = Message(id: UUID(), role: .user, content: "nope", timestamp: Date(), toolCalls: [])
        #expect(throws: SessionPersistenceError.self) {
            try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: cid, message: blocked)
        }
    }
}
