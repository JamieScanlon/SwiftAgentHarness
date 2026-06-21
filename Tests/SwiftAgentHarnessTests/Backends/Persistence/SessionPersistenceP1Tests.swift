import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence P1 (SessionBackend-shaped API)")
struct SessionPersistenceP1Tests {

    @Test func catalogPageKeysetAndLineage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var record = SessionCatalogRecord(
            id: cid,
            topic: "Alpha",
            description: nil,
            messageCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try local.bootstrapEmptyConversation(record)

        let m1 = Message(id: UUID(), role: .system, content: "s", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let e1 = try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: e1)
        let m2 = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let e2 = try SessionTranscriptMapping.entry(from: m2, sequence: 2, parentEntryId: SessionEntryID.fromMessageUUID(m1.id))
        try local.appendTranscriptEntry(conversationID: cid, entry: e2)

        let p1 = try local.listCatalogConversationsPage(cursor: nil, limit: 5)
        #expect(p1.records.count == 1)
        let filtered = try local.listConversations(
            SessionConversationListFilter(
                agentId: SessionPersistenceLayout.defaultAgentId,
                source: nil,
                cwd: nil,
                lifecycleState: nil,
                since: nil
            ),
            limit: 5,
            cursor: nil
        )
        #expect(filtered.records.count == 1)
        let lin = try local.transcriptLineage(conversationID: cid, entryId: SessionEntryID.fromMessageUUID(m2.id), maxDepth: 8)
        #expect(lin.count == 2)
        #expect(lin.first?.entryId == SessionEntryID.fromMessageUUID(m2.id))

        let u = try local.transcriptEntry(conversationID: cid, entryId: SessionEntryID.fromMessageUUID(m1.id))
        #expect(u.sequence == 1)
        let kids = try local.childTranscriptEntries(conversationID: cid, parentEntryId: SessionEntryID.fromMessageUUID(m1.id))
        #expect(kids.count == 1)
        #expect(kids[0].entryId == SessionEntryID.fromMessageUUID(m2.id))

        let prompt = try local.firstUserPromptText(conversationID: cid)
        #expect(prompt == "hi")
    }

    @Test func forkCopiesPrefixAndSearchFindsPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p1-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let parentId = UUID()
        let record = SessionCatalogRecord(
            id: parentId,
            topic: "P",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)
        let a = Message(id: UUID(), role: .user, content: "uniqueTokenXYZ", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let ea = try SessionTranscriptMapping.entry(from: a, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: parentId, entry: ea)

        let childId = UUID()
        let forked = try local.forkConversation(parentConversationID: parentId, atEntryId: SessionEntryID.fromMessageUUID(a.id), newConversationId: childId, title: "Child")
        #expect(forked.id == childId)
        #expect(forked.title == "Child")
        let childEntries = try local.readTranscriptEntries(conversationID: childId, request: .full)
        #expect(childEntries.count == 1)
        #expect(childEntries[0].payloadJSON.contains("uniqueTokenXYZ"))

        let children = try local.childConversations(parentConversationID: parentId)
        #expect(children.contains { $0.id == childId })

        let hits = try local.searchTranscriptMessages(query: "uniqueTokenXYZ", agentId: nil, conversationID: nil, limit: 10)
        #expect(hits.contains { $0.conversationID == childId })
    }

    @Test func compactionEntryAppendsWithDistinctType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p1-compact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "c",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)
        let compactionWire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: cid,
            harnessCheckpointKind: HarnessCheckpointWireKind.contextCompaction.rawValue,
            compactionCheckpointKind: "summarized",
            coveredRawMessageIDs: [],
            basedOnTailMessageID: nil,
            invalidatedCheckpointKinds: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let compactionJSON = String(data: try enc.encode(compactionWire), encoding: .utf8)!
        let seq = try local.recordTranscriptCompactionEntry(conversationID: cid, payloadJSON: compactionJSON)
        #expect(seq == 1)
        let entries = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(entries.count == 1)
        #expect(entries[0].type == .compaction)
    }

    @Test func jsonlCodecPreservesUnknownHarnessTypeAsCustom() throws {
        let entry = SessionTranscriptEntry(
            sequence: 1,
            entryId: .generate(),
            parentEntryId: nil,
            type: .custom,
            harnessTypeRaw: "totally_new_future_type",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            payloadJSON: "{}"
        )
        let data = try SessionJSONLTranscriptCodec.jsonlData(for: entry)
        let back = try SessionJSONLTranscriptCodec.entry(fromLineJSON: data)
        #expect(back.type == .custom)
        #expect(back.harnessTypeRaw == "totally_new_future_type")
    }

    @Test func updateConversationUpdatesCatalogAndEnforcesRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p1-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "Before",
                description: "old",
                messageCount: 0,
                updatedAt: Date(timeIntervalSince1970: 10),
                createdAt: Date(timeIntervalSince1970: 10),
                modelName: "m-old",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        let before = try #require(try local.catalogConversation(id: cid))

        var patch = SessionConversationUpdatePatch()
        patch.topic = .set("After")
        patch.description = .set(nil)
        patch.modelName = .set("m-new")
        patch.lifecycleStateRaw = .set(ConversationLifecycleState.archived.rawValue)
        patch.updatedAt = .set(Date(timeIntervalSince1970: 20))
        let updated = try local.updateSessionConversation(
            conversationID: cid,
            patch: patch,
            expectedRevision: UInt64(before.controlPlaneRevision)
        )
        #expect(updated.topic == "After")
        #expect(updated.description == nil)
        #expect(updated.modelName == "m-new")
        #expect(updated.lifecycleStateRaw == ConversationLifecycleState.archived.rawValue)
        #expect(updated.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(updated.controlPlaneRevision == before.controlPlaneRevision + 1)

        #expect(throws: SessionPersistenceError.self) {
            var stalePatch = SessionConversationUpdatePatch()
            stalePatch.topic = .set("Rejected")
            _ = try local.updateSessionConversation(
                conversationID: cid,
                patch: stalePatch,
                expectedRevision: UInt64(before.controlPlaneRevision)
            )
        }
    }

    @Test func inMemoryUpdateConversationSupportsPatchFields() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let cid = UUID()
        try mem.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T0",
                description: "D0",
                messageCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1),
                createdAt: Date(timeIntervalSince1970: 1),
                modelName: "m0",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        var patch = SessionConversationUpdatePatch()
        patch.topic = .set("T1")
        patch.modeProfileID = .set("profile.agent")
        patch.interactionModeRaw = .set(InteractionMode.agent.rawValue)
                patch.updatedAt = .set(Date(timeIntervalSince1970: 2))
        let updated = try mem.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: nil)
        #expect(updated.topic == "T1")
        #expect(updated.modeProfileID == "profile.agent")
        #expect(updated.interactionModeRaw == InteractionMode.agent.rawValue)
                #expect(updated.updatedAt == Date(timeIntervalSince1970: 2))
    }

}
