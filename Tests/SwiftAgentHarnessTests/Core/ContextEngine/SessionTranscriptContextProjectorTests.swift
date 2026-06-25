import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("SessionTranscriptContextProjector renderable-head invariant (CR-C)")
struct SessionTranscriptContextProjectorTests {

    private func messageEntry(_ message: Message, sequence: Int) throws -> SessionTranscriptEntry {
        try SessionTranscriptMapping.entry(from: message, sequence: sequence, parentEntryId: nil)
    }

    private func compactionEntry(
        conversationID: UUID,
        summary: String?,
        firstKeptMessageID: UUID,
        sequence: Int
    ) throws -> SessionTranscriptEntry {
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: conversationID,
            summary: summary,
            firstKeptEntryID: SessionEntryID.fromMessageUUID(firstKeptMessageID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: try encoder.encode(wire), encoding: .utf8))
        return SessionTranscriptEntry(
            sequence: sequence,
            entryId: SessionEntryID.generate(),
            parentEntryId: nil,
            type: .compaction,
            timestamp: Date(),
            payloadJSON: json
        )
    }

    /// Builds a transcript whose compaction anchor (`firstKeptEntryID`) resolves to a
    /// `.tool` message whose originating assistant tool-call sits in the dropped prefix.
    private func transcript(
        conversationID: UUID,
        summary: String?
    ) throws -> (entries: [SessionTranscriptEntry], systemID: UUID, toolID: UUID, trailingUserID: UUID) {
        let systemMsg = Message(id: UUID(), role: .system, content: "You are a helpful agent.", timestamp: Date(), toolCalls: [])
        let firstUser = Message(id: UUID(), role: .user, content: "first question", timestamp: Date(), toolCalls: [])
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "create_plan", arguments: .object([:]), id: "call-1")]
        )
        let toolResult = Message(
            id: UUID(),
            role: .tool,
            content: "Created plan.md (15 tasks).",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "call-1"
        )
        let trailingUser = Message(id: UUID(), role: .user, content: "please continue", timestamp: Date(), toolCalls: [])

        let entries: [SessionTranscriptEntry] = [
            try compactionEntry(
                conversationID: conversationID,
                summary: summary,
                firstKeptMessageID: toolResult.id,
                sequence: 0
            ),
            try messageEntry(systemMsg, sequence: 1),
            try messageEntry(firstUser, sequence: 2),
            try messageEntry(assistant, sequence: 3),
            try messageEntry(toolResult, sequence: 4),
            try messageEntry(trailingUser, sequence: 5),
        ]
        return (entries, systemMsg.id, toolResult.id, trailingUser.id)
    }

    @Test("projection never begins on an orphaned leading tool result")
    func leadingToolRemoved() throws {
        let cid = UUID()
        let built = try transcript(conversationID: cid, summary: nil)

        let projected = SessionTranscriptContextProjector.projectMessages(
            entries: built.entries,
            fallbackMessages: []
        )

        #expect(projected.first?.role != .tool)
        // The orphaned tool result (assistant tool-call trimmed) must not survive.
        #expect(!projected.contains { $0.role == .tool && $0.toolCallId == "call-1" })
    }

    @Test("system prompt survives compaction and summary is carried as .system")
    func systemPreservedAcrossCompaction() throws {
        let cid = UUID()
        let built = try transcript(conversationID: cid, summary: "Earlier work summary.")

        let projected = SessionTranscriptContextProjector.projectMessages(
            entries: built.entries,
            fallbackMessages: []
        )

        #expect(projected.contains { $0.role == .system })
        // Summary must be re-injected as a system message, never as a user turn.
        #expect(projected.contains { $0.role == .system && $0.content == "Earlier work summary." })
        #expect(!projected.contains { $0.role == .user && $0.content == "Earlier work summary." })
    }

    @Test("regression: previously unrenderable head is system-led, tool-pair-consistent, and keeps the trailing user turn")
    func unrenderableHeadIsRepairedEndToEnd() throws {
        let cid = UUID()
        let built = try transcript(conversationID: cid, summary: nil)

        let projected = SessionTranscriptContextProjector.projectMessages(
            entries: built.entries,
            fallbackMessages: []
        )

        // The array that previously triggered "No user query found in messages." now renders:
        // leads with a system message, carries no orphaned tool result, and preserves the user turn.
        #expect(projected.first?.role == .system)
        #expect(!projected.contains { $0.role == .tool })
        #expect(projected.contains { $0.role == .user && $0.content == "please continue" })
    }
}
