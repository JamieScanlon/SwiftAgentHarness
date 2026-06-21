import Foundation
import Testing
@testable import SwiftAgentHarness

struct ConversationsRegistryTopicHubTests {
    @Test func payloadRoundTripsJSON() throws {
        let id = UUID()
        let payload = ConversationsRegistryPayload(
            changes: [
                ConversationRegistryChange(kind: .added, conversationID: id, metadata: nil)
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConversationsRegistryPayload.self, from: data)
        #expect(decoded.changes.count == 1)
        #expect(decoded.changes[0].kind == .added)
        #expect(decoded.changes[0].conversationID == id)
    }

    @Test func subscribeReplaysWhenSinceIsInWindow() async throws {
        let hub = ConversationsRegistryTopicHub()

        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribeConversationsRegistry(token: recvToken, since: 0) {
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .added, conversationID: UUID())],
                updatedAt: Date()
            )
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: lagData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)

        await hub.unregisterConnection(recvToken)
    }

    @Test func subscribeSendsLaggingWhenReplayRangeFallsOutsideWindow() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.conversationsRegistryEvents = 1
        let hub = ConversationsRegistryTopicHub(replayCapacities: replayCapacities)
        let topic = ResourceTopicName.conversationsRegistry

        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )
        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribeConversationsRegistry(token: recvToken, since: 0) {
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .added, conversationID: UUID())],
                updatedAt: Date()
            )
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let lag = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.topic == topic)
        #expect(lag.seq == 2)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)

        await hub.unregisterConnection(recvToken)
    }

    @Test func inProcessConversationsRegistrySubscribeReceivesSnapshotThenEvents() async throws {
        let hub = ConversationsRegistryTopicHub()
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }

        await hub.subscribeConversationsRegistryInProcess(token: token, since: nil) {
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .added, conversationID: UUID())],
                updatedAt: Date()
            )
        }
        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<ConversationsRegistryPayload>.self, from: eventData)
        #expect(event.kind == .event)
    }

    @Test func strictGovernanceRejectsInvalidRegistrySchemaWithoutSeqAdvance() async throws {
        let hub = ConversationsRegistryTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                schemaVersion: 999,
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )
        #expect(await hub.currentSeq(forTopic: ResourceTopicName.conversationsRegistry) == 0)
    }

    @Test func softGovernanceAllowsInvalidRegistrySchemaAndAdvancesSeq() async throws {
        let hub = ConversationsRegistryTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .soft, diagnosticsEnabled: true)
        )
        await hub.broadcastConversationsRegistry(
            ConversationsRegistryPayload(
                schemaVersion: 999,
                changes: [ConversationRegistryChange(kind: .updated, conversationID: UUID())],
                updatedAt: Date()
            )
        )
        #expect(await hub.currentSeq(forTopic: ResourceTopicName.conversationsRegistry) == 1)
    }
}
