import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationTopicWireDecoding")
struct ConversationTopicWireDecodingTests {
    @Test("Text delta round-trips to ChatStreamingPartial")
    func textRoundTrip() throws {
        let wire = ModelPoolContentDeltaMapping.textFragment(fragment: "hello", blockIndex: 0)
        let payload = ConversationTopicWireEncoding.contentDeltaPayload(wire: wire)
        let line = try encodeLine(payload: payload)
        let decoded = ConversationTopicWireDecoding.decodeEvent(line: line)
        if case .partial(.text("hello"), _, _, _, _) = decoded {
            // ok
        } else {
            Issue.record("Expected text partial decode")
        }
    }

    @Test("Reasoning delta round-trips to ChatStreamingPartial")
    func reasoningRoundTrip() throws {
        let wire = ModelPoolContentDeltaMapping.reasoningFragment(fragment: "think", blockIndex: 2)
        let payload = ConversationTopicWireEncoding.contentDeltaReasoningFragmentPayload(
            text: "think",
            blockIndex: 2
        )
        let line = try encodeLine(payload: payload)
        let decoded = ConversationTopicWireDecoding.decodeEvent(line: line)
        if case .partial(.reasoning("think", blockIndex: 2), _, _, _, _) = decoded {
            // ok
        } else {
            Issue.record("Expected reasoning partial decode")
        }
    }

    @Test("Tool-call delta round-trips to ChatStreamingPartial")
    func toolCallRoundTrip() throws {
        let payload = ConversationTopicWireEncoding.contentDeltaToolCallFragmentPayload(
            toolName: "search",
            toolCallId: "call-1",
            argumentsFragment: "{\"q",
            blockIndex: nil
        )
        let line = try encodeLine(payload: payload)
        let decoded = ConversationTopicWireDecoding.decodeEvent(line: line)
        if case .partial(
            .toolCall(toolName: "search", toolCallId: "call-1", argumentsFragment: "{\"q", blockIndex: nil),
            _, _, _, _
        ) = decoded {
            // ok
        } else {
            Issue.record("Expected tool-call partial decode")
        }
    }

    @Test("Decodes messagesRefresh rows from array and object shapes")
    func messagesRefreshRows() throws {
        let message = Message(id: UUID(), role: .assistant, content: "committed")
        let json = ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: [message])
        let fromArray = ConversationTopicWireDecoding.decodeMessagesRefreshRows(json)
        #expect(fromArray.count == 1)
        #expect(fromArray[0].content == "committed")

        let objectJSON = ConversationTopicWireEncoding.messagesRefreshJSONUTF8(from: [message], latestTranscriptSequence: 3)
        let fromObject = ConversationTopicWireDecoding.decodeMessagesRefreshRows(objectJSON)
        #expect(fromObject.count == 1)
        #expect(fromObject[0].id == message.id)
    }

    @Test("Decodes runtimeLifecycle and streamDone events")
    func lifecycleAndStreamDone() throws {
        let cid = UUID()
        let runID = UUID()
        let lifecycle = RuntimeLifecycleEventPayload(
            name: .turnCompleted,
            conversationID: cid,
            runID: runID,
            source: "tests"
        )
        let lifecycleLine = try encodeLine(
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: lifecycle),
            runID: runID,
            turnOrdinal: 4
        )
        if case .runtimeLifecycle(let payload, _, _) = ConversationTopicWireDecoding.decodeEvent(line: lifecycleLine) {
            #expect(payload.name == .turnCompleted)
            #expect(payload.runID == runID)
        } else {
            Issue.record("Expected runtimeLifecycle decode")
        }

        let streamDoneLine = try encodeLine(payload: .streamDone, runID: runID, turnOrdinal: 3)
        if case .streamDone(let decodedRunID, _, let turnOrdinal) = ConversationTopicWireDecoding.decodeEvent(line: streamDoneLine) {
            #expect(decodedRunID == runID)
            #expect(turnOrdinal == 3)
        } else {
            Issue.record("Expected streamDone decode")
        }
    }

    private func encodeLine(
        payload: ConversationTopicEventPayload,
        runID: UUID? = nil,
        turnOrdinal: Int? = nil
    ) throws -> String {
        let envelope: CommResourceTopicMessage<ConversationTopicEventPayload>
        if let runID, let turnOrdinal {
            envelope = CommResourceTopicMessage(
                transientEvent: "conversation/\(UUID().uuidString)/events",
                seq: 1,
                value: payload,
                runId: runID,
                turnOrdinal: turnOrdinal
            )
        } else {
            envelope = CommResourceTopicMessage(
                event: "conversation/\(UUID().uuidString)/events",
                seq: 1,
                value: payload
            )
        }
        let data = try JSONEncoder().encode(envelope)
        return try #require(String(data: data, encoding: .utf8))
    }
}
