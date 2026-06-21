import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Harness session persistence Gap 5 (single v2 transcript writer)")
struct SessionPersistenceGap5Tests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "gap5",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test func rollBackLastMirroredAppendRestoresEmptyTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap5-rb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "t",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.modelName = makeModel().modelName
        try local.bootstrapEmptyConversation(row)

        let lock = try local.acquireTranscriptWriteLock(conversationID: cid, allowReentrant: false)
        defer { lock.unlock() }

        let msg = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        let entry = try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil, transcriptRunID: nil)
        try local.appendTranscriptEntryUnlocked(conversationID: cid, entry: entry)
        #expect(try local.latestTranscriptSequence(conversationID: cid) == 1)

        try local.rollBackLastMirroredTranscriptAppend(conversationID: cid, entry: entry)
        #expect(try local.latestTranscriptSequence(conversationID: cid) == 0)
    }

    @Test func truncateLastEntryLineDropsFinalJSONLRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap5-jsonl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        let cid = UUID()
        try SessionJSONLTranscriptWriter(fileURL: url).writeFreshHeader(conversationId: cid)
        let w = SessionJSONLTranscriptWriter(fileURL: url)
        try w.appendEntryLine(Data(#"{"s":1}"#.utf8))
        try w.appendEntryLine(Data(#"{"s":2}"#.utf8))
        try SessionJSONLTranscriptWriter.truncateLastEntryLine(fileURL: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(String(lines[1]).contains("s\":1"))
    }
}
