import Foundation
import Testing
@testable import SwiftAgentHarness

struct SubAgentLifecycleTopicHubTests {
    @Test func subscribeReplaysWhenSinceIsInWindow() async throws {
        let hub = SubAgentLifecycleTopicHub()
        let conversationID = UUID()
        let pathSegments = ["agent-0", "agent-2"]
        let topic = SubAgentTopicFormat.eventsTopic(conversationID: conversationID, pathSegments: pathSegments)

        let payload = SubAgentLifecycleTopicPayload(
            parentConversationID: conversationID,
            entries: [
                SubAgentLifecycleEntryPayload(
                    lifecycleID: "l-1",
                    parentConversationID: conversationID,
                    phase: .running
                )
            ]
        )
        await hub.broadcastEvent(conversationID: conversationID, pathSegments: pathSegments, payload: payload)

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: token,
            topic: topic,
            parentConversationID: conversationID,
            since: 0
        ) { _ in
            SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let replayData = try #require(collector.lines[0].data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<SubAgentLifecycleTopicPayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)
        #expect(replay.trustClass == .restricted)
        #expect(replay.originTrust == .unknownParty)
        let snapData = try #require(collector.lines[1].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<SubAgentLifecycleTopicPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)
        #expect(snap.trustClass == .trusted)
        #expect(snap.originTrust == .system)
    }

    @Test func inProcessSubscriberReceivesSnapshotAndEventAfterSubscribe() async throws {
        let hub = SubAgentLifecycleTopicHub()
        let conversationID = UUID()
        let pathSegments = ["agent-1"]
        let topic = SubAgentTopicFormat.eventsTopic(conversationID: conversationID, pathSegments: pathSegments)

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }

        await hub.subscribeInProcess(
            token: token,
            topic: topic,
            parentConversationID: conversationID,
            since: nil
        ) { _ in
            SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
        }

        let payload = SubAgentLifecycleTopicPayload(
            parentConversationID: conversationID,
            entries: [
                SubAgentLifecycleEntryPayload(
                    lifecycleID: "l-2",
                    parentConversationID: conversationID,
                    phase: .done
                )
            ]
        )
        await hub.broadcastEvent(conversationID: conversationID, pathSegments: pathSegments, payload: payload)

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<SubAgentLifecycleTopicPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.trustClass == .trusted)
        #expect(snap.originTrust == .system)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<SubAgentLifecycleTopicPayload>.self, from: eventData)
        #expect(event.kind == .event)
        #expect(event.trustClass == .restricted)
        #expect(event.originTrust == .unknownParty)
    }

    @Test func eventTrustLevelOverridesDefaultTrustLevelForEnvelopeTrust() async throws {
        let hub = SubAgentLifecycleTopicHub()
        let conversationID = UUID()
        let pathSegments = ["agent-9"]
        let topic = SubAgentTopicFormat.eventsTopic(conversationID: conversationID, pathSegments: pathSegments)

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }
        try await hub.subscribe(
            token: token,
            topic: topic,
            parentConversationID: conversationID,
            since: nil
        ) { _ in
            SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
        }
        let payload = SubAgentLifecycleTopicPayload(
            parentConversationID: conversationID,
            entries: [
                SubAgentLifecycleEntryPayload(
                    lifecycleID: "l-9",
                    parentConversationID: conversationID,
                    phase: .running,
                    eventTrustLevel: SubAgentTrustLevel.system.rawValue,
                    defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue
                )
            ]
        )
        await hub.broadcastEvent(conversationID: conversationID, pathSegments: pathSegments, payload: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let eventData = try #require(collector.lines.last?.data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<SubAgentLifecycleTopicPayload>.self, from: eventData)
        #expect(event.trustClass == .trusted)
        #expect(event.originTrust == .system)
    }
}
