import Foundation
import Testing
@testable import SwiftAgentHarness

struct ConversationStateTopicHubTests {
    @Test func deletedPayloadRoundTripsJSON() throws {
        let id = UUID()
        let payload = ConversationStatePayload.deleted(conversationID: id)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConversationStatePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.exists == false)
        #expect(decoded.sessionSelected == false)
        #expect(decoded.poolModelState == nil)
    }

    @Test func payloadWithPoolModelStateRoundTripsJSON() throws {
        let cid = UUID()
        let pool = ModelStatePayload(
            phase: .streaming,
            thinking: true,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 0),
            inFlightCount: 1
        )
        let payload = ConversationStatePayload(
            conversationID: cid,
            exists: true,
            sessionSelected: true,
            topic: "t",
            modelID: UUID(),
            modelName: "m",
            orchestration: nil,
            replayActive: false,
            poolModelState: pool
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConversationStatePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.poolModelState?.phase == .streaming)
        #expect(decoded.poolModelState?.thinking == true)
        #expect(decoded.poolModelState?.inFlightCount == 1)
    }

    @Test func subscribeReplaysMissedEventsWhenSinceIsInWindow() async throws {
        let hub = ConversationStateTopicHub()
        let cid = UUID()

        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                topic: "t",
                orchestration: nil,
                replayActive: false
            )
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: recvToken,
            conversationID: cid,
            since: 0
        ) { _ in
            ConversationStatePayload(conversationID: cid, exists: true, sessionSelected: true, orchestration: nil, replayActive: false)
        }

        #expect(collector.lines.count == 2)
        let replayData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)
        #expect(snap.value?.sessionSelected == true)

        await hub.unregisterConnection(recvToken)
    }

    @Test func subscribeSendsLaggingWhenReplayRangeFallsOutsideWindow() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.conversationStateEvents = 1
        let hub = ConversationStateTopicHub(replayCapacities: replayCapacities)
        let cid = UUID()
        let topic = ConversationTopicFormat.stateTopic(conversationID: cid)

        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                topic: "t-1",
                orchestration: nil,
                replayActive: false
            )
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                topic: "t-2",
                orchestration: nil,
                replayActive: false
            )
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: recvToken,
            conversationID: cid,
            since: 0
        ) { _ in
            ConversationStatePayload(conversationID: cid, exists: true, sessionSelected: true, orchestration: nil, replayActive: false)
        }

        #expect(collector.lines.count == 2)
        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let lag = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.topic == topic)
        #expect(lag.seq == 2)
        #expect(lag.hint == "resync")

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)

        await hub.unregisterConnection(recvToken)
    }

    @Test func inProcessSubscribeReceivesSnapshotThenEvents() async throws {
        let hub = ConversationStateTopicHub()
        let cid = UUID()
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }

        await hub.subscribeInProcess(token: token, conversationID: cid, since: nil) { _ in
            ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                orchestration: nil,
                replayActive: false
            )
        }
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                conversationID: cid,
                exists: true,
                sessionSelected: true,
                orchestration: nil,
                replayActive: false
            )
        )

        #expect(collector.lines.count == 2)
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try JSONDecoder().decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: eventData)
        #expect(event.kind == .event)
    }

    @Test func strictGovernanceRejectsInvalidStateSchemaWithoutSeqAdvance() async throws {
        let hub = ConversationStateTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                schemaVersion: 999,
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                orchestration: nil,
                replayActive: false
            )
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func softGovernanceAllowsInvalidStateSchemaAndAdvancesSeq() async throws {
        let hub = ConversationStateTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .soft, diagnosticsEnabled: true)
        )
        let cid = UUID()
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationStatePayload(
                schemaVersion: 999,
                conversationID: cid,
                exists: true,
                sessionSelected: false,
                orchestration: nil,
                replayActive: false
            )
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 1)
    }
}
