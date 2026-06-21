import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("In-memory harness session persistence")
struct InMemoryHarnessSessionPersistenceTests {
    @Test func bootstrapAppendAndRoundTrip() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let cid = UUID()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "M",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try mem.bootstrapEmptyConversation(record)
        let m1 = Message(
            id: UUID(),
            role: .system,
            content: "s",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        let e1 = try SessionTranscriptMapping.entry(from: m1, sequence: 1, parentEntryId: nil)
        try mem.appendTranscriptEntry(conversationID: cid, entry: e1)
        let read = try mem.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(read.count == 1)
        #expect(read[0].entryId == SessionEntryID.fromMessageUUID(m1.id))

        let listed = try mem.listCatalogConversations()
        #expect(listed.count == 1)
    }

    @Test func listKeysetCursorUsesUpdatedAtThenIdOrdering() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let highID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try mem.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: lowID,
                topic: "low",
                description: nil,
                messageCount: 0,
                updatedAt: ts,
                createdAt: ts,
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        try mem.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: highID,
                topic: "high",
                description: nil,
                messageCount: 0,
                updatedAt: ts,
                createdAt: ts,
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )

        let page1 = try mem.listCatalogConversationsPage(cursor: nil, limit: 1)
        #expect(page1.records.count == 1)
        #expect(page1.records[0].id == highID)
        let page2 = try mem.listCatalogConversationsPage(cursor: page1.nextCursor, limit: 1)
        #expect(page2.records.count == 1)
        #expect(page2.records[0].id == lowID)
    }

    @Test func forkConversationCopiesPrefixAndSetsLineageFields() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let parentID = UUID()
        try mem.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: parentID,
                topic: "Parent",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        let system = Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        let user = Message(id: UUID(), role: .user, content: "fork-prefix-token", timestamp: Date(), images: [], toolCalls: [], toolCallId: nil, responseFormat: nil, inputTrustRaw: nil)
        try mem.appendTranscriptEntry(conversationID: parentID, entry: try SessionTranscriptMapping.entry(from: system, sequence: 1, parentEntryId: nil))
        try mem.appendTranscriptEntry(conversationID: parentID, entry: try SessionTranscriptMapping.entry(from: user, sequence: 2, parentEntryId: SessionEntryID.fromMessageUUID(system.id)))

        let childID = UUID()
        let forked = try mem.forkConversation(
            parentConversationID: parentID,
            atEntryId: SessionEntryID.fromMessageUUID(user.id),
            newConversationId: childID,
            title: "Child"
        )
        #expect(forked.id == childID)
        #expect(forked.parentConversationID == parentID)
        #expect(forked.forkAnchorEntryID == SessionEntryID.fromMessageUUID(user.id))
        #expect(forked.title == "Child")
        let childEntries = try mem.readTranscriptEntries(conversationID: childID, request: .full)
        #expect(childEntries.count == 2)
        #expect(childEntries.contains { $0.payloadJSON.contains("fork-prefix-token") })
    }

    @Test("updateTranscriptEntryPayload round-trips under concurrent reads")
    func concurrentPayloadUpdateAndReads() async throws {
        let mem = InMemoryHarnessSessionPersistence()
        let cid = UUID()
        try mem.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "concurrent",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        let message = Message(
            id: UUID(),
            role: .user,
            content: "initial",
            timestamp: Date(),
            images: [],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: nil
        )
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        try mem.appendTranscriptEntry(conversationID: cid, entry: entry)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 32 {
                group.addTask { @Sendable in
                    _ = try mem.readTranscriptEntries(conversationID: cid, request: .full)
                    _ = try mem.latestTranscriptSequence(conversationID: cid)
                    _ = try mem.searchTranscriptMessages(query: "initial", agentId: nil, conversationID: cid, limit: 10)
                }
                group.addTask { @Sendable in
                    var updated = entry
                    updated.payloadJSON = "{\"iteration\":\(i)}"
                    try mem.updateTranscriptEntryPayload(conversationID: cid, entry: updated)
                }
            }
            for try await _ in group {}
        }

        let final = try mem.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(final.count == 1)
        #expect(final[0].entryId == entry.entryId)
        #expect(final[0].sequence == 1)
        #expect(final[0].payloadJSON.contains("iteration"))
    }
}
