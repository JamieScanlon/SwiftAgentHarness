import Foundation
import Testing
@testable import SwiftAgentHarness

private actor JSONCollector {
    private(set) var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
    }
}

@Suite("ModelStateTopicHub")
struct ModelStateTopicHubTests {

    @Test func seqIncrementsPerModelTopicOnBroadcast() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        #expect(await hub.currentSeq(forModelID: modelID) == 0)
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .done, thinking: false)
        )
        #expect(await hub.currentSeq(forModelID: modelID) == 1)
    }

    @Test func inProcessSubscriberReceivesSnapshotAndEventAfterExplicitSubscribe() async throws {
        let hub = ModelStateTopicHub()
        let collector = JSONCollector()
        let token = await hub.registerInProcessSubscriber { json in
            await collector.append(json)
        }
        let modelID = UUID()
        try await Task.sleep(nanoseconds: 1_000_000)
        await hub.subscribeInProcess(token: token, modelID: modelID, since: nil) { _ in
            ModelStatePayload(phase: .connecting, thinking: false)
        }
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .streaming, thinking: true, callId: UUID())
        )
        await hub.unregisterInProcessSubscriber(token)
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .done, thinking: false)
        )
        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: eventData)
        #expect(event.kind == .event)
        #expect(event.topic == ModelStateTopicFormat.topic(modelID: modelID))
    }

    @Test func modelPoolResourceTopicPublishingRoutesThroughHub() async throws {
        let hub = ModelStateTopicHub()
        let publisher: any ModelPoolResourceTopicPublishing = hub
        let collector = JSONCollector()
        let token = await hub.registerInProcessSubscriber { json in
            await collector.append(json)
        }
        let modelID = UUID()
        await hub.subscribeInProcess(token: token, modelID: modelID, since: nil) { _ in
            ModelStatePayload(phase: .connecting, thinking: false)
        }
        await publisher.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .connecting, thinking: false)
        )
        #expect(await collector.lines.count == 2)
    }

    @Test func inProcessReplayAndLaggingMatchWireSemantics() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.modelStateEvents = 1
        let hub = ModelStateTopicHub(replayCapacities: replayCapacities)
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)

        await hub.broadcast(modelID: modelID, payload: ModelStatePayload(phase: .connecting, thinking: false))
        await hub.broadcast(modelID: modelID, payload: ModelStatePayload(phase: .streaming, thinking: true))

        let collector = JSONCollector()
        let token = await hub.registerInProcessSubscriber { json in
            await collector.append(json)
        }
        await hub.subscribeInProcess(token: token, modelID: modelID, since: 0) { _ in
            ModelStatePayload(phase: .done, thinking: false)
        }

        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lagData = try #require(lines[0].data(using: .utf8))
        let lag = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.topic == topic)
        #expect(lag.seq == 2)
        let snapData = try #require(lines[1].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)
    }

    @Test func subscribeReplaysMissedModelStateEventsWhenSinceIsInWindow() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .streaming, thinking: true)
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: 0
        ) { _ in
            ModelStatePayload(phase: .done, thinking: false)
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let replayData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 2)

        await hub.unregisterConnection(token)
    }

    @Test func subscribeSendsLaggingWhenReplayRangeFallsOutsideWindow() async throws {
        var replayCapacities = TopicReplayCapacityConfiguration.default
        replayCapacities.modelStateEvents = 1
        let hub = ModelStateTopicHub(replayCapacities: replayCapacities)
        let modelID = UUID()
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .connecting, thinking: false)
        )
        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .streaming, thinking: true)
        )

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: 0
        ) { _ in
            ModelStatePayload(phase: .done, thinking: false)
        }

        #expect(collector.lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let lag = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.seq == 2)
        #expect(lag.hint == "resync")

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)

        await hub.unregisterConnection(token)
    }

    @Test func subscribeReplaysMissedEventsWhenSinceMatchesPriorSnapshotSeq() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: nil
        ) { _ in
            ModelStatePayload(phase: .connecting, thinking: false)
        }
        #expect(collector.lines.count == 1)

        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .streaming, thinking: true)
        )
        #expect(collector.lines.count == 2)

        let beforeResubscribe = collector.lines.count
        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: 1
        ) { _ in
            ModelStatePayload(phase: .streaming, thinking: true)
        }

        let newLines = Array(collector.lines.dropFirst(beforeResubscribe))
        #expect(newLines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let replayData = try #require(newLines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 2)
        #expect(replay.topic == topic)

        let snapData = try #require(newLines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)
        #expect(snap.topic == topic)

        await hub.unregisterConnection(token)
    }

    @Test func subscribeInProcessReplaysMissedEventsWhenSinceMatchesPriorSnapshotSeq() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)

        let collector = JSONCollector()
        let token = await hub.registerInProcessSubscriber { json in
            await collector.append(json)
        }

        await hub.subscribeInProcess(token: token, modelID: modelID, since: nil) { _ in
            ModelStatePayload(phase: .connecting, thinking: false)
        }
        #expect(await collector.lines.count == 1)

        await hub.broadcast(
            modelID: modelID,
            payload: ModelStatePayload(phase: .streaming, thinking: true)
        )
        #expect(await collector.lines.count == 2)

        let beforeResubscribe = await collector.lines.count
        await hub.subscribeInProcess(token: token, modelID: modelID, since: 1) { _ in
            ModelStatePayload(phase: .streaming, thinking: true)
        }

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

        let snapData = try #require(newLines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)
        #expect(snap.topic == topic)

        await hub.unregisterInProcessSubscriber(token)
    }

    @Test func coordinatorPublicationSinkPopulatesReplayForResubscribe() async throws {
        let hub = ModelStateTopicHub()
        let modelID = UUID()
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await hub.broadcast(modelID: modelID, payload: payload)
        }

        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }

        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: nil
        ) { mid in
            await coordinator.snapshot(for: mid)
        }
        #expect(collector.lines.count == 1)

        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        #expect(collector.lines.count == 2)

        let beforeResubscribe = collector.lines.count
        try await hub.subscribe(
            token: token,
            modelID: modelID,
            since: 1
        ) { mid in
            await coordinator.snapshot(for: mid)
        }

        let newLines = Array(collector.lines.dropFirst(beforeResubscribe))
        #expect(newLines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let replayData = try #require(newLines.first?.data(using: .utf8))
        let replay = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 2)
        #expect(replay.topic == topic)

        let snapData = try #require(newLines.last?.data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelStatePayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)
        #expect(snap.topic == topic)

        await hub.unregisterConnection(token)
    }

    @Test func modelCallsTopicInProcessSubscriberReceivesSnapshotAndEvent() async throws {
        let hub = ModelStateTopicHub()
        let collector = JSONCollector()
        let token = await hub.registerInProcessSubscriber { json in
            await collector.append(json)
        }
        let modelID = UUID()
        await hub.subscribeModelCallsInProcess(token: token, modelID: modelID, since: nil) { mid in
            ModelCallsPayload(modelID: mid, active: [])
        }
        let call = ModelCallRecord(
            callID: UUID(),
            conversationID: UUID(),
            phase: .streaming,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        await hub.broadcastModelCalls(
            modelID: modelID,
            payload: ModelCallsPayload(modelID: modelID, active: [call], recent: [])
        )
        let lines = await collector.lines
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapData = try #require(lines[0].data(using: .utf8))
        let snap = try decoder.decode(CommResourceTopicMessage<ModelCallsPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(lines[1].data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<ModelCallsPayload>.self, from: eventData)
        #expect(event.kind == .event)
        #expect(event.value?.active.first?.callID == call.callID)
    }
}
