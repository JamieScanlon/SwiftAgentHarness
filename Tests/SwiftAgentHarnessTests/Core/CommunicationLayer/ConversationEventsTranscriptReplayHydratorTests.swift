import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationEventsTranscriptReplayHydrator")
struct ConversationEventsTranscriptReplayHydratorTests {
    @Test func legacyReplayEncodesPersistedSeqFromTranscriptRow() throws {
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let runID = UUID()
        let msg = Message(id: UUID(), role: .user, content: "hydrate-replay", timestamp: Date())
        let entry = try SessionTranscriptMapping.entry(from: msg, sequence: 1, parentEntryId: nil, transcriptRunID: runID)
        let (lines, lagging) = ConversationEventsTranscriptReplayHydrator.persistedReplayLines(
            topic: topic,
            conversationID: cid,
            replay: .totalOrderSince(0),
            entries: [entry],
            latestTranscriptSequence: 1
        )
        #expect(lagging == false)
        #expect(lines.count == 1)
        let data = try #require(lines[0].data(using: .utf8))
        let env = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: data)
        #expect(env.seq == 1)
        #expect(env.messageSeq == 1)
        #expect(env.checkpointSeq == nil)
    }

    @Test func dualReplayOrdersMessageAndCheckpointBySequence() throws {
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let u = Message(id: UUID(), role: .user, content: "u", timestamp: Date())
        let e1 = try SessionTranscriptMapping.entry(from: u, sequence: 1, parentEntryId: nil)
        let chk = ConversationCheckpointTopicEventWire(
            variant: .checkpointInvalidation,
            conversationID: cid,
            invalidatedCheckpointKinds: ["a"]
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let chkJSON = try #require(String(data: try enc.encode(chk), encoding: .utf8))
        let e2 = SessionTranscriptEntry(
            sequence: 2,
            entryId: .generate(),
            parentEntryId: nil,
            type: .compaction,
            timestamp: Date(),
            payloadJSON: chkJSON
        )
        let (lines, lagging) = ConversationEventsTranscriptReplayHydrator.persistedReplayLines(
            topic: topic,
            conversationID: cid,
            replay: .dual(sinceMessage: 0, sinceCheckpoint: 0),
            entries: [e2, e1],
            latestTranscriptSequence: 2
        )
        #expect(lagging == false)
        #expect(lines.count == 2)
        let d0 = try #require(lines[0].data(using: .utf8))
        let d1 = try #require(lines[1].data(using: .utf8))
        let env0 = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: d0)
        let env1 = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: d1)
        #expect(env0.seq == 1 && env0.messageSeq == 1)
        #expect(env1.seq == 2 && env1.checkpointSeq == 2)
    }
}
