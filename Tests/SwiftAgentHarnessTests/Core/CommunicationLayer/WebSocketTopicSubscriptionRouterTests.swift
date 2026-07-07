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

    @Test func subscribeModelStateWithSinceReplaysWhenRangeAvailable() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await hub.broadcast(modelID: modelID, payload: payload)
        }
        let catalog = SubscribeRouterModelManagerDouble(models: [WebSocketRouterTestFixtures.model(id: modelID)])

        let collector = RouterLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }

        let initialError = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: coordinator,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: catalog,
            message: CommClientControlMessage(kind: .subscribe, topic: topic, since: nil),
            registration: registration
        )
        #expect(initialError == nil)
        #expect(await collector.lines.count == 1)

        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        #expect(await collector.lines.count == 2)

        let beforeResubscribe = await collector.lines.count
        let resubscribeError = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: coordinator,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: catalog,
            message: CommClientControlMessage(kind: .subscribe, topic: topic, since: 1),
            registration: registration
        )
        #expect(resubscribeError == nil)

        let allLines = await collector.lines
        let newLines = Array(allLines.dropFirst(beforeResubscribe))
        #expect(newLines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let replayData = try #require(newLines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 2)
        #expect(replay.topic == topic)

        let snapshotData = try #require(newLines.last?.data(using: .utf8))
        let snapshot = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapshotData)
        #expect(snapshot.kind == .snapshot)
        #expect(snapshot.seq == 3)
        #expect(snapshot.topic == topic)
    }

    @Test func subscribeModelStateWithSinceFallsBackToLaggingWhenOutOfWindow() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        let coordinator = ModelInvocationCoordinator()
        let catalog = SubscribeRouterModelManagerDouble(models: [WebSocketRouterTestFixtures.model(id: modelID)])

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
            coordinator: coordinator,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: catalog,
            message: CommClientControlMessage(kind: .subscribe, topic: topic, since: 999),
            registration: registration
        )

        #expect(error == nil)
        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let laggingData = try #require(lines.first?.data(using: .utf8))
        let lagging = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: laggingData)
        #expect(lagging.kind == .lagging)
        #expect(lagging.topic == topic)
        #expect(lagging.seq == 0)
        #expect(lagging.hint == "resync")

        let snapshotData = try #require(lines.last?.data(using: .utf8))
        let snapshot = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapshotData)
        #expect(snapshot.kind == .snapshot)
        #expect(snapshot.topic == topic)
        #expect(snapshot.seq == 1)
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
