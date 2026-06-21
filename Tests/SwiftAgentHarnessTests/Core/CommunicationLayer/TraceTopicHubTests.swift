import Foundation
import Testing
@testable import SwiftAgentHarness

struct TraceTopicHubTests {
    @Test func subscribeConversationTraceReplaysAndSnapshots() async throws {
        let hub = TraceTopicHub()
        let cid = UUID()
        let topic = TraceTopicFormat.conversationTopic(conversationID: cid)
        let traceID = UUID()
        await hub.broadcastConversation(
            conversationID: cid,
            payload: TraceTopicPayload(
                spans: [TraceSpanPayload(traceID: traceID, name: "turn.started", category: "runtime", source: "tests", conversationID: cid)]
            )
        )

        final class Collector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = Collector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }
        try await hub.subscribe(token: token, topic: topic, since: 0) {
            TraceTopicPayload(spans: [])
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let replayData = try #require(collector.lines[0].data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<TraceTopicPayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)
        #expect(replay.trustClass == .trusted)
        #expect(replay.originTrust == .system)
        let snapData = try #require(collector.lines[1].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<TraceTopicPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)
        #expect(snap.trustClass == .trusted)
        #expect(snap.originTrust == .system)
    }

    @Test func inProcessServerTraceSubscriberReceivesSnapshotAndEvent() async throws {
        let hub = TraceTopicHub()
        let topic = TraceTopicFormat.serverTopic
        let traceID = UUID()

        final class Collector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = Collector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }
        await hub.subscribeInProcess(token: token, topic: topic, since: nil) {
            TraceTopicPayload(spans: [])
        }
        await hub.broadcastServer(
            payload: TraceTopicPayload(
                spans: [TraceSpanPayload(traceID: traceID, name: "server.start", category: "server", source: "tests")]
            )
        )

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<TraceTopicPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.trustClass == .trusted)
        #expect(snap.originTrust == .system)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<TraceTopicPayload>.self, from: eventData)
        #expect(event.kind == .event)
        #expect(event.trustClass == .trusted)
        #expect(event.originTrust == .system)
    }
}
