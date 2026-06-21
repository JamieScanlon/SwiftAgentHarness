import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence Gap 15 — README compaction / branch summary parity")
struct SessionPersistenceGap15Tests {
    @Test func readmeCompactionHelperRoundTripsWireFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-gap15-c-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let firstKept = SessionEntryID.generate()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "g15",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)

        let details: [String: SessionTranscriptJSONValue] = [
            "reason": .string("test"),
            "nested": .object(["n": .int(1)]),
        ]
        let compactionSeq = try local.recordTranscriptCompaction(
            conversationID: cid,
            summary: "trimmed middle",
            firstKeptEntryID: firstKept,
            tokensBefore: 9000,
            details: details
        )
        #expect(compactionSeq == 1)

        let entries = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(entries.count == 1)
        #expect(entries[0].type == .compaction)

        let decoded = try SessionTranscriptPayloadAllowlist.decodeCompactionCheckpointPayload(entries[0].payloadJSON)
        #expect(decoded.conversationID == cid)
        #expect(decoded.summary == "trimmed middle")
        #expect(decoded.firstKeptEntryID == firstKept)
        #expect(decoded.tokensBefore == 9000)
        #expect(decoded.details == details)
    }

    @Test func readmeBranchSummaryHelperRoundTripsWireFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-gap15-b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let fromEntry = SessionEntryID.generate()
        let record = SessionCatalogRecord(
            id: cid,
            topic: "g15b",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)

        let details: [String: SessionTranscriptJSONValue] = ["k": .bool(true)]
        let branchSummarySeq = try local.recordTranscriptBranchSummary(
            conversationID: cid,
            fromEntryID: fromEntry,
            summary: "branch note",
            details: details,
            payloadVersion: 2
        )
        #expect(branchSummarySeq == 1)

        let entries = try local.readTranscriptEntries(conversationID: cid, request: .full)
        #expect(entries.count == 1)
        #expect(entries[0].type == .branchSummary)

        let decoded = try SessionTranscriptPayloadAllowlist.decodeBranchSummaryPayload(entries[0].payloadJSON)
        #expect(decoded.version == 2)
        #expect(decoded.summary == "branch note")
        #expect(decoded.fromEntryID == fromEntry)
        #expect(decoded.details == details)
    }

    @Test func branchSummaryPayloadBackwardCompatibleDecode() throws {
        let json = #"{"version":1,"summary":"legacy minimal"}"#
        let decoded = try SessionTranscriptPayloadAllowlist.decodeBranchSummaryPayload(json)
        #expect(decoded.version == 1)
        #expect(decoded.summary == "legacy minimal")
        #expect(decoded.fromEntryID == nil)
        #expect(decoded.details == nil)
    }
}
