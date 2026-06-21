
import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Transcript payload allowlist")
struct SessionTranscriptPayloadAllowlistTests {
    @Test func messageMappingPayloadUsesOnlyAllowlistedKeys() throws {
        let m = Message(
            id: UUID(),
            role: .assistant,
            content: "hi",
            timestamp: Date(),
            images: [],
            toolCalls: [ToolCall(name: "search", arguments: .object(["q": .string("x")]), id: "tc-1")],
            toolCallId: nil,
            responseFormat: "text",
            inputTrustRaw: nil
        )
        let entry = try SessionTranscriptMapping.entry(from: m, sequence: 1, parentEntryId: nil)
        let data = try #require(entry.payloadJSON.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys).isSubset(of: SessionTranscriptPayloadAllowlist.messageTranscriptJSONKeyAllowlist))
        #expect(obj["v"] as? Int == MessageTranscriptPayload.currentVersion)
    }

    @Test func rejectsUnknownKeysInAssertPath() throws {
        let badId = UUID().uuidString
        let bad = "{\"id\":\"\(badId)\",\"role\":\"user\",\"content\":\"x\",\"timestamp\":0,\"extra\":1}"
        #expect(throws: SessionPersistenceError.self) {
            try SessionTranscriptPayloadAllowlist.assertMessagePayloadKeysAllowed(bad)
        }
    }

    @Test func compactionPayloadRoundTripWire() throws {
        let cid = UUID()
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: cid,
            harnessCheckpointKind: HarnessCheckpointWireKind.contextCompaction.rawValue,
            compactionCheckpointKind: "summarized",
            coveredRawMessageIDs: [.generate()],
            basedOnTailMessageID: nil,
            invalidatedCheckpointKinds: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: try enc.encode(wire), encoding: .utf8))
        let decoded = try SessionTranscriptPayloadAllowlist.decodeCompactionCheckpointPayload(json)
        #expect(decoded.conversationID == cid)
    }
}
