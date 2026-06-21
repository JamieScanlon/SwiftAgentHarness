import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness tree head_entry_id + readLineage")
struct SessionTreeHeadEntryTests {

    @Test func appendAdvancesHeadAndReadLineageIsRootToLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-tree-head-\(UUID().uuidString)", isDirectory: true)
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
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        try local.bootstrapEmptyConversation(record)

        let m1 = Message(id: UUID(), role: .system, content: "s", timestamp: Date(), toolCalls: [])
        let e1 = try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: e1)

        let m2 = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let e2 = try SessionTranscriptMapping.entry(
            from: m2,
            sequence: 2,
            parentEntryId: SessionEntryID.fromMessageUUID(m1.id)
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: e2)

        let head = try #require(try local.activeHeadEntryId(conversationID: cid))
        #expect(head == SessionEntryID.fromMessageUUID(m2.id))

        let lineage = try local.readLineage(conversationID: cid, leafEntryId: head)
        #expect(lineage.count == 2)
        #expect(lineage[0].entryId == SessionEntryID.fromMessageUUID(m1.id))
        #expect(lineage[1].entryId == SessionEntryID.fromMessageUUID(m2.id))

        let leafFirst = try local.transcriptLineage(
            conversationID: cid,
            entryId: head,
            maxDepth: 8
        )
        #expect(leafFirst.first?.entryId == head)
        #expect(leafFirst.last?.entryId == SessionEntryID.fromMessageUUID(m1.id))
    }

    @Test func setActiveHeadEntryIdRewindsToAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-tree-rewind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )

        let m1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        let e1 = try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: e1)
        let m2 = Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: [])
        let e2 = try SessionTranscriptMapping.entry(
            from: m2,
            sequence: 2,
            parentEntryId: SessionEntryID.fromMessageUUID(m1.id)
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: e2)

        let anchor = SessionEntryID.fromMessageUUID(m1.id)
        _ = try local.setActiveHeadEntryId(conversationID: cid, entryId: anchor, expectedRevision: nil)
        #expect(try local.activeHeadEntryId(conversationID: cid) == anchor)

        let lineage = try local.readLineage(conversationID: cid, leafEntryId: anchor)
        #expect(lineage.count == 1)
        #expect(lineage[0].entryId == anchor)

        let all = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(all.count == 2)
    }

    @Test func setActiveHeadEntryIdRejectsOffBranchEntry() throws {
        let local = InMemoryHarnessSessionPersistence()
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )

        let root = Message(id: UUID(), role: .system, content: "s", timestamp: Date(), toolCalls: [])
        let u1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        let a1 = Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: [])
        let u2 = Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: [])

        let eRoot = try SessionTranscriptMapping.entry(from: root, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: eRoot)
        let eU1 = try SessionTranscriptMapping.entry(
            from: u1,
            sequence: 2,
            parentEntryId: SessionEntryID.fromMessageUUID(root.id)
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: eU1)
        let eA1 = try SessionTranscriptMapping.entry(
            from: a1,
            sequence: 3,
            parentEntryId: SessionEntryID.fromMessageUUID(u1.id)
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: eA1)
        _ = try local.setActiveHeadEntryId(
            conversationID: cid,
            entryId: SessionEntryID.fromMessageUUID(u1.id),
            expectedRevision: nil
        )
        let eU2 = try SessionTranscriptMapping.entry(
            from: u2,
            sequence: 4,
            parentEntryId: SessionEntryID.fromMessageUUID(u1.id)
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: eU2)

        #expect(throws: SessionPersistenceError.self) {
            try local.setActiveHeadEntryId(
                conversationID: cid,
                entryId: SessionEntryID.fromMessageUUID(a1.id),
                expectedRevision: nil
            )
        }
    }
}
