import Foundation
import Testing
@testable import SwiftAgentHarness

struct CapabilityRegistryTopicHubTests {
    @Test func toolsPayloadRoundTripsJSON() throws {
        let id = UUID()
        let payload = ToolsRegistryPayload(
            conversationID: id,
            tools: [
                AvailableToolInfo(
                    name: "t1",
                    description: "d",
                    source: .local,
                    normalizedSchemaFingerprint: "abc123",
                    normalizedSchemaVersion: "1",
                    normalizedTopLevelType: "object",
                    normalizedRequiredCount: 1,
                    normalizedPropertyCount: 2
                ),
                AvailableToolInfo(name: "t2", description: "d2", source: .a2a)
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ToolsRegistryPayload.self, from: data)
        #expect(decoded.tools.count == 2)
        #expect(decoded.tools[0].normalizedSchemaFingerprint == "abc123")
        #expect(decoded.tools[0].normalizedSchemaVersion == "1")
        #expect(decoded.tools[0].normalizedTopLevelType == "object")
        #expect(decoded.tools[0].normalizedRequiredCount == 1)
        #expect(decoded.tools[0].normalizedPropertyCount == 2)
        #expect(decoded.tools[1].source == .a2a)
        #expect(decoded.conversationID == id)
    }

    @Test func subscribeToolsRegistryReplaysWhenSinceIsInWindow() async throws {
        let hub = CapabilityRegistryTopicHub()

        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(conversationID: UUID(), tools: [], updatedAt: Date())
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribeToolsRegistry(token: recvToken, since: 0) {
            ToolsRegistryPayload(conversationID: nil, tools: [], updatedAt: Date())
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: lagData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)

        await hub.unregisterConnection(recvToken)
    }

    @Test func subscribeToolsRegistrySendsLaggingWhenReplayRangeFallsOutsideWindow() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.capabilityRegistryEvents = 1
        let hub = CapabilityRegistryTopicHub(replayCapacities: replayCapacities)
        let topic = ResourceTopicName.toolsRegistry

        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(conversationID: UUID(), tools: [], updatedAt: Date())
        )
        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(conversationID: UUID(), tools: [], updatedAt: Date())
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let recvToken = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribeToolsRegistry(token: recvToken, since: 0) {
            ToolsRegistryPayload(conversationID: nil, tools: [], updatedAt: Date())
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let lag = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.topic == topic)
        #expect(lag.seq == 2)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)

        await hub.unregisterConnection(recvToken)
    }

    @Test func inProcessToolsRegistrySubscribeReceivesSnapshotThenEvents() async throws {
        let hub = CapabilityRegistryTopicHub()
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }

        await hub.subscribeToolsRegistryInProcess(token: token, since: nil) {
            ToolsRegistryPayload(conversationID: nil, tools: [], updatedAt: Date())
        }
        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(conversationID: UUID(), tools: [], updatedAt: Date())
        )

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<ToolsRegistryPayload>.self, from: eventData)
        #expect(event.kind == .event)
    }

    @Test func strictGovernanceRejectsInvalidToolsRegistrySchema() async throws {
        let hub = CapabilityRegistryTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(schemaVersion: 999, conversationID: UUID(), tools: [], updatedAt: Date())
        )
        #expect(await hub.currentSeq(forTopic: ResourceTopicName.toolsRegistry) == 0)
    }

    @Test func softGovernanceAllowsInvalidToolsRegistrySchema() async throws {
        let hub = CapabilityRegistryTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .soft, diagnosticsEnabled: true)
        )
        await hub.broadcastToolsRegistry(
            ToolsRegistryPayload(schemaVersion: 999, conversationID: UUID(), tools: [], updatedAt: Date())
        )
        #expect(await hub.currentSeq(forTopic: ResourceTopicName.toolsRegistry) == 1)
    }

    @Test func subAgentsPayloadV2RoundTripsJSON() throws {
        let id = UUID()
        let payload = SubAgentsRegistryPayload(
            schemaVersion: SubAgentsRegistryPayload.schemaVersionV2,
            conversationID: id,
            agents: [
                AvailableToolInfo(name: "delegate_research", description: "research", source: .a2a)
            ],
            entries: [
                SubAgentRegistryEntryPayload(
                    agentID: "delegate_research",
                    displayName: "delegate_research",
                    description: "research",
                    delegateToolName: "delegate_research",
                    source: .a2a,
                    transportKind: "a2a",
                    useClasses: ["research"],
                    maxRecursionDepth: 2,
                    streaming: true,
                    longRunning: false,
                    defaultTrustLevel: "known-party",
                    permissionPolicy: "ask-user",
                    hostPersonaID: "coding-agent",
                    delegationAllowlist: ["delegate_research"],
                    authScopeTags: ["repo:read"],
                    routingDomain: "engineering",
                    tenantScope: "default",
                    tool: AvailableToolInfo(name: "delegate_research", description: "research", source: .a2a)
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SubAgentsRegistryPayload.self, from: data)
        #expect(decoded.schemaVersion == SubAgentsRegistryPayload.schemaVersionV2)
        #expect(decoded.conversationID == id)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].delegateToolName == "delegate_research")
        #expect(decoded.entries[0].defaultTrustLevel == "known-party")
        #expect(decoded.entries[0].hostPersonaID == "coding-agent")
        #expect(decoded.entries[0].authScopeTags == ["repo:read"])
    }

    @Test func strictGovernanceRejectsInvalidSubAgentsRegistrySchema() async throws {
        let hub = CapabilityRegistryTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        await hub.broadcastSubAgentsRegistry(
            SubAgentsRegistryPayload(
                schemaVersion: SubAgentsRegistryPayload.schemaVersionV1,
                conversationID: UUID(),
                agents: [],
                entries: [],
                updatedAt: Date()
            )
        )
        #expect(await hub.currentSeq(forTopic: ResourceTopicName.subAgentsRegistry) == 0)
    }
}
