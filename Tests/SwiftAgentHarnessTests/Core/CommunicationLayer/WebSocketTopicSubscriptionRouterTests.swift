import Foundation
import Testing
@testable import SwiftAgentHarness

private actor RouterLineCollector {
    private(set) var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
    }
}

struct WebSocketTopicSubscriptionRouterTests {
    @Test func subscribePoolHealthWithSinceReplaysWhenRangeAvailable() async throws {
        let hub = ModelStateTopicHub()
        await hub.broadcastPoolHealth(
            PoolHealthPayload(queueDepth: 1, inFlight: 1, maxConcurrent: 4)
        )

        let collector = RouterLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }

        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: ResourceTopicName.poolHealth, since: 0),
            registration: registration
        )

        #expect(error == nil)
        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let replayData = try #require(lines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<PoolHealthPayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)
        let snapshotData = try #require(lines.last?.data(using: .utf8))
        let snapshot = try decoder.decode(CommResourceTopicMessage<PoolHealthPayload>.self, from: snapshotData)
        #expect(snapshot.kind == .snapshot)
        #expect(snapshot.seq == 2)
    }

    @Test func subscribePoolHealthWithSinceFallsBackToLaggingWhenOutOfWindow() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.poolHealthEvents = 1
        let hub = ModelStateTopicHub(replayCapacities: replayCapacities)
        await hub.broadcastPoolHealth(
            PoolHealthPayload(queueDepth: 1, inFlight: 0, maxConcurrent: 4)
        )
        await hub.broadcastPoolHealth(
            PoolHealthPayload(queueDepth: 2, inFlight: 0, maxConcurrent: 4)
        )

        let collector = RouterLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }

        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: ResourceTopicName.poolHealth, since: 0),
            registration: registration
        )

        #expect(error == nil)
        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let laggingData = try #require(lines.first?.data(using: .utf8))
        let lagging = try decoder.decode(CommResourceTopicMessage<PoolHealthPayload>.self, from: laggingData)
        #expect(lagging.kind == .lagging)
        #expect(lagging.seq == 2)
        let snapshotData = try #require(lines.last?.data(using: .utf8))
        let snapshot = try decoder.decode(CommResourceTopicMessage<PoolHealthPayload>.self, from: snapshotData)
        #expect(snapshot.kind == .snapshot)
        #expect(snapshot.seq == 3)
    }

    @Test func subscribeSubAgentPathTopicParsesNewShape() async {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let topic = "subagent/\(cid.uuidString.lowercased())/agent-0/agent-2/events"
        let registration = WebSocketTopicWireRegistration()
        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: topic, since: nil),
            registration: registration
        )
        #expect(error == "Sub-agent lifecycle wire is not configured on this server")
    }

    @Test func subscribeSubAgentLegacyTopicShapeIsRejected() async {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let legacyTopic = "subagent/\(cid.uuidString.lowercased())/events"
        let registration = WebSocketTopicWireRegistration()
        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: legacyTopic, since: nil),
            registration: registration
        )
        #expect(SubAgentTopicFormat.parse(legacyTopic) == nil)
        #expect(error != "Sub-agent lifecycle wire is not configured on this server")
    }

    @Test func subscribeTraceConversationTopicParsesNewShape() async {
        let cid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let topic = TraceTopicFormat.conversationTopic(conversationID: cid)
        let registration = WebSocketTopicWireRegistration()
        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: topic, since: nil),
            registration: registration
        )
        #expect(error == "Trace wire is not configured on this server")
    }

    @Test func subscribeTraceServerTopicParsesShape() async {
        let registration = WebSocketTopicWireRegistration()
        let error = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: TraceTopicFormat.serverTopic, since: nil),
            registration: registration
        )
        #expect(error == "Trace wire is not configured on this server")
    }
}
