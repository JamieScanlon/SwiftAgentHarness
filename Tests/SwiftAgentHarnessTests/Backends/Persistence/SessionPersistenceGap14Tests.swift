import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence Gap 14 (retention on snapshot reads)")
struct SessionPersistenceGap14Tests {
    @Test func localReadWithFloorBeyondLagThrowsRetentionExceeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap14-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try HarnessEnvironmentOverride.$overrides.withValue(["SAH_TRANSCRIPT_TAIL_MAX_SEQUENCE_LAG": "2"]) {
            let local = try LocalHarnessSessionPersistence(root: root)
            let cid = UUID()
            var row = SessionCatalogRecord(
                id: cid,
                topic: "gap14-\(cid.uuidString)",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
            row.agentId = SessionPersistenceLayout.defaultAgentId
            try local.bootstrapEmptyConversation(row)

            for _ in 0 ..< 5 {
                let seq = try local.nextTranscriptSequence(conversationID: cid)
                let entry = SessionTranscriptEntry(
                    sequence: seq,
                    entryId: .generate(),
                    parentEntryId: nil,
                    type: .message,
                    timestamp: Date(),
                    payloadJSON: "{}"
                )
                try local.appendTranscriptEntry(conversationID: cid, entry: entry)
            }
            #expect(try local.latestTranscriptSequence(conversationID: cid) == 5)

            #expect(throws: SessionPersistenceError.self) {
                try local.readTranscriptEntries(conversationID: cid, request: .init(fromSequence: 1))
            }

            let tail = try local.readTranscriptEntries(conversationID: cid, request: .init(fromSequence: 3))
            #expect(tail.count == 3)

            let all = try local.readTranscriptEntries(conversationID: cid, request: .full)
            #expect(all.count == 5)
        }
    }

    @Test func inMemoryReadWithFloorBeyondLagThrows() throws {
        try HarnessEnvironmentOverride.$overrides.withValue(["SAH_TRANSCRIPT_TAIL_MAX_SEQUENCE_LAG": "2"]) {
            let mem = InMemoryHarnessSessionPersistence()
            let cid = UUID()
            var row = SessionCatalogRecord(
                id: cid,
                topic: "g14m-\(cid.uuidString)",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
            row.agentId = SessionPersistenceLayout.defaultAgentId
            try mem.bootstrapEmptyConversation(row)

            for _ in 0 ..< 5 {
                let seq = try mem.nextTranscriptSequence(conversationID: cid)
                let entry = SessionTranscriptEntry(
                    sequence: seq,
                    entryId: .generate(),
                    parentEntryId: nil,
                    type: .message,
                    timestamp: Date(),
                    payloadJSON: "{}"
                )
                try mem.appendTranscriptEntry(conversationID: cid, entry: entry)
            }

            #expect(throws: SessionPersistenceError.self) {
                try mem.readTranscriptEntries(conversationID: cid, request: .init(fromSequence: 0))
            }
            let ok = try mem.readTranscriptEntries(conversationID: cid, request: .full)
            #expect(ok.count == 5)
        }
    }

    @Test func readRequestSupportsToSequenceAndLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap14-bounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let mem = InMemoryHarnessSessionPersistence()
        let localID = UUID()
        let memID = UUID()

        var localRow = SessionCatalogRecord(
            id: localID,
            topic: "local",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        localRow.agentId = SessionPersistenceLayout.defaultAgentId
        try local.bootstrapEmptyConversation(localRow)

        var memRow = SessionCatalogRecord(
            id: memID,
            topic: "mem",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        memRow.agentId = SessionPersistenceLayout.defaultAgentId
        try mem.bootstrapEmptyConversation(memRow)

        for _ in 0 ..< 5 {
            let localSeq = try local.nextTranscriptSequence(conversationID: localID)
            let localEntry = SessionTranscriptEntry(
                sequence: localSeq,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                timestamp: Date(),
                payloadJSON: "{}"
            )
            try local.appendTranscriptEntry(conversationID: localID, entry: localEntry)

            let memSeq = try mem.nextTranscriptSequence(conversationID: memID)
            let memEntry = SessionTranscriptEntry(
                sequence: memSeq,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                timestamp: Date(),
                payloadJSON: "{}"
            )
            try mem.appendTranscriptEntry(conversationID: memID, entry: memEntry)
        }

        let request = SessionTranscriptReadRequest(fromSequence: 2, toSequence: 4, limit: 2)
        let localOut = try local.readTranscriptEntries(conversationID: localID, request: request)
        let memOut = try mem.readTranscriptEntries(conversationID: memID, request: request)
        #expect(localOut.map(\.sequence) == [2, 3])
        #expect(memOut.map(\.sequence) == [2, 3])
    }
}
