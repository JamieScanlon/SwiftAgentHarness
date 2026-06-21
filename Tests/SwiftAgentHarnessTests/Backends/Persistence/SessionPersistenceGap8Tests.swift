import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence FTS (content + MessageHit)")
struct SessionPersistenceGap8Tests {
    @Test func searchHitsIncludeSnippetScoreTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var record = SessionCatalogRecord(
            id: cid,
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(record)

        let msg = Message(
            id: UUID(),
            role: .user,
            content: "gammaSearchToken822",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        let entry = try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: entry)

        let hits = try local.searchTranscriptMessages(query: "gammaSearchToken822", agentId: nil, conversationID: nil, limit: 25)
        #expect(hits.count == 1)
        let h = try #require(hits.first)
        #expect(h.conversationID == cid)
        #expect(h.entryId == SessionEntryID.fromMessageUUID(msg.id))
        #expect(h.sequence == 1)
        #expect(h.snippet.contains("gammaSearchToken822"))
        #expect(h.snippet.contains(SessionFTS5SearchConstants.snippetHighlightStart))
        #expect(h.score.isFinite)
        #expect(abs(h.timestamp.timeIntervalSince1970 - 1_800_000_000) < 1)
    }

    @Test func searchAgentIdFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root, agentId: "agentA")
        let cid = UUID()
        var record = SessionCatalogRecord(
            id: cid,
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.agentId = "agentA"
        try local.bootstrapEmptyConversation(record)
        let msg = Message(
            id: UUID(),
            role: .user,
            content: "onlyOnAgentA",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        let entry = try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: entry)

        let wrong = try local.searchTranscriptMessages(query: "onlyOnAgentA", agentId: "other", conversationID: nil, limit: 10)
        #expect(wrong.isEmpty)
        let ok = try local.searchTranscriptMessages(query: "onlyOnAgentA", agentId: "agentA", conversationID: nil, limit: 10)
        #expect(ok.count == 1)
    }

    @Test func catalogMigrationWritesSchemaVersion9InRecoveryIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-ver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var record = SessionCatalogRecord(
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
        let url = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
        let data = try Data(contentsOf: url)
        let obj = try JSONDecoder().decode(RecoveryIndexStub.self, from: data)
        #expect(obj.catalogSchemaVersion == SQLiteSessionCatalog.kSupportedCatalogSchemaVersion)
    }

    @Test func searchSurvivesCatalogReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cid = UUID()
        do {
            let local = try LocalHarnessSessionPersistence(root: root)
            var record = SessionCatalogRecord(
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
            let msg = Message(
                id: UUID(),
                role: .user,
                content: "persistFtsBody",
                timestamp: Date(),
                images: [],
                toolCalls: [],
                toolCallId: nil,
                responseFormat: nil,
                inputTrustRaw: nil
            )
            let entry = try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil)
            try local.appendTranscriptEntry(conversationID: cid, entry: entry)
        }
        let local2 = try LocalHarnessSessionPersistence(root: root)
        let hits = try local2.searchTranscriptMessages(query: "persistFtsBody", agentId: nil, conversationID: nil, limit: 5)
        #expect(hits.count == 1)
    }

    @Test func searchOrderIsDeterministicForTieLikeRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var record = SessionCatalogRecord(
            id: cid,
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(record)

        let m1 = Message(id: UUID(), role: .user, content: "sameTokenForOrder", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let m2 = Message(id: UUID(), role: .assistant, content: "sameTokenForOrder", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil))
        try local.appendTranscriptEntry(conversationID: cid, entry: try SessionTranscriptMapping.entry(from: m2, sequence: 2, parentEntryId: nil))

        let hits = try local.searchTranscriptMessages(query: "sameTokenForOrder", agentId: nil, conversationID: nil, limit: 10)
        #expect(hits.map(\.sequence) == [1, 2])
    }

    @Test func conversationFilterMissingReturnsEmptyOnBothBackends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let mem = InMemoryHarnessSessionPersistence()
        let missing = UUID()
        let query = "tokenThatDoesNotMatter"

        let localHits = try local.searchTranscriptMessages(query: query, agentId: nil, conversationID: missing, limit: 10)
        let memHits = try mem.searchTranscriptMessages(query: query, agentId: nil, conversationID: missing, limit: 10)
        #expect(localHits.isEmpty)
        #expect(memHits.isEmpty)
    }

    @Test func sqliteFtsTriggersReflectMessageUpdateAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap8-triggers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cid = UUID()
        do {
            let local = try LocalHarnessSessionPersistence(root: root)
            var record = SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
            record.agentId = SessionPersistenceLayout.defaultAgentId
            try local.bootstrapEmptyConversation(record)
            let msg = Message(id: UUID(), role: .user, content: "oldBodyToken", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
            try local.appendTranscriptEntry(conversationID: cid, entry: try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil))
        }

        let catalog = try SQLiteSessionCatalog(fileURL: SessionPersistenceLayout.catalogURL(root: root))
        try catalog.exec("UPDATE messages SET content = 'newBodyToken' WHERE conversation_id = '\(cid.uuidString)' AND sequence = 1;")

        let oldMatch = FTS5QuerySanitizer.matchAndPhrases("oldBodyToken")
        let newMatch = FTS5QuerySanitizer.matchAndPhrases("newBodyToken")
        let oldHitsAfterUpdate = try catalog.searchTranscriptMessages(matchSQL: oldMatch, agentId: nil, conversationID: cid, limit: 10)
        let newHitsAfterUpdate = try catalog.searchTranscriptMessages(matchSQL: newMatch, agentId: nil, conversationID: cid, limit: 10)
        #expect(oldHitsAfterUpdate.isEmpty)
        #expect(newHitsAfterUpdate.count == 1)

        try catalog.exec("DELETE FROM messages WHERE conversation_id = '\(cid.uuidString)' AND sequence = 1;")
        let hitsAfterDelete = try catalog.searchTranscriptMessages(matchSQL: newMatch, agentId: nil, conversationID: cid, limit: 10)
        #expect(hitsAfterDelete.isEmpty)
    }

    private struct RecoveryIndexStub: Decodable {
        var catalogSchemaVersion: Int
    }
}
