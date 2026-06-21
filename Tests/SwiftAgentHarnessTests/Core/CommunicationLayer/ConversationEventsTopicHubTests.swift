import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationEventsTopicHub")
struct ConversationEventsTopicHubTests {

    private static func canonicalJSONUTF8(for jsonUTF8: String) throws -> String {
        guard let data = jsonUTF8.data(using: .utf8) else {
            throw NSError(domain: "ConversationEventsTopicHubTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid UTF-8"])
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        let normalizedData = try JSONSerialization.data(withJSONObject: parsed as Any, options: [.sortedKeys])
        return String(decoding: normalizedData, as: UTF8.self)
    }

    private static func harnessMessages(fromJSONArrayWire jsonUTF8: String) throws -> [Message] {
        guard let data = jsonUTF8.data(using: .utf8) else {
            throw NSError(domain: "tests", code: 1)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "tests", code: 2)
        }
        return rows.compactMap { Message.fromJSON($0) }
    }

    private static func assertMessagesDecodedEquivalent(fromJSONWire: String, originals: [Message]) throws {
        let decoded = try harnessMessages(fromJSONArrayWire: fromJSONWire)
        #expect(decoded.count == originals.count)
        for (decoded, original) in zip(decoded, originals) {
            #expect(decoded.id == original.id)
            #expect(decoded.role == original.role)
            #expect(decoded.content == original.content)
        }
    }

    private static func encodePersistedEventLine(
        topic: String,
        seq: Int,
        payload: ConversationTopicEventPayload,
        messageSeq: Int?,
        checkpointSeq: Int?
    ) throws -> String {
        let envelope = CommResourceTopicMessage<ConversationTopicEventPayload>(
            event: topic,
            seq: seq,
            value: payload,
            messageSeq: messageSeq,
            checkpointSeq: checkpointSeq
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(envelope)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func contentDeltaWireRoundTripsThroughPayloadJSON() throws {
        let wire = ModelPoolContentDeltaMapping.textFragment(fragment: "hi", blockIndex: 0)
        let payload = ConversationTopicWireEncoding.contentDeltaPayload(wire: wire)
        #expect(payload.semanticKind == .contentDelta)
        let json = try #require(payload.jsonUTF8)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ModelContentDeltaWire.self, from: data)
        #expect(decoded == wire)
    }

    @Test func replayInclusiveFloorMapsLegacyAndDualCursors() {
        #expect(
            ConversationEventsTranscriptReplayHydrator.replayInclusiveFloor(.totalOrderSince(nil))
                == nil
        )
        #expect(
            ConversationEventsTranscriptReplayHydrator.replayInclusiveFloor(.totalOrderSince(4))
                == 5
        )
        #expect(
            ConversationEventsTranscriptReplayHydrator.replayInclusiveFloor(
                .dual(sinceMessage: 9, sinceCheckpoint: 2)
            ) == 3
        )
    }

    @Test func contentDeltaReasoningRoundTripsThroughConveniencePayload() throws {
        let wire = ModelPoolContentDeltaMapping.reasoningFragment(fragment: "think step", blockIndex: 1)
        let payload = ConversationTopicWireEncoding.contentDeltaReasoningFragmentPayload(text: "think step", blockIndex: 1)
        #expect(payload.semanticKind == .contentDelta)
        let json = try #require(payload.jsonUTF8)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ModelContentDeltaWire.self, from: data)
        #expect(decoded == wire)
    }

    @Test func contentDeltaToolCallRoundTripsThroughConveniencePayload() throws {
        let wire = ModelPoolContentDeltaMapping.toolCallFragment(
            toolName: "get_plan",
            toolCallId: "call-1",
            argumentsFragment: "{\"",
            blockIndex: nil
        )
        let payload = ConversationTopicWireEncoding.contentDeltaToolCallFragmentPayload(
            toolName: "get_plan",
            toolCallId: "call-1",
            argumentsFragment: "{\"",
            blockIndex: nil
        )
        #expect(payload.semanticKind == .contentDelta)
        let json = try #require(payload.jsonUTF8)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ModelContentDeltaWire.self, from: data)
        #expect(decoded == wire)
    }

    @Test func persistedBroadcastSetsSeqFromTranscriptSequence() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
        await hub.broadcastPersisted(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.messagesRefreshPayload(messages: []),
            transcriptSequence: 9
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 9)
        #expect(await hub.currentMessageSeq(forConversationID: cid) == 9)
        #expect(await hub.currentCheckpointSeq(forConversationID: cid) == 0)
    }

    @Test func transientBroadcastsAdvanceWireSeqWithoutChangingPersistedHead() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let runtimePayload = RuntimeLifecycleEventPayload(
            name: .turnStarted,
            conversationID: cid,
            runID: UUID(),
            source: "tests"
        )
        await hub.broadcastPersisted(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.messagesRefreshPayload(messages: []),
            transcriptSequence: 7
        )
        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "a", runId: nil, callId: nil),
            runID: UUID(),
            modelCallId: nil
        )
        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: runtimePayload),
            runID: UUID(),
            modelCallId: nil
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 9)
        #expect(await hub.currentMessageSeq(forConversationID: cid) == 7)
    }

    @Test func runtimeLifecycleTrustUsesOriginTrustLevelWhenPresent() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }
        try await hub.subscribe(
            token: token,
            conversationID: cid,
            since: nil,
            transcriptReplay: ConversationTranscriptSubscribeReplay(
                latestTotal: 0,
                latestMessage: 0,
                latestCheckpoint: 0,
                persistedReplayLines: [],
                forceLagging: false
            ),
            snapshotMessagesJSONUTF8: { _ in ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: []) },
            snapshotTranscriptSequence: 0
        )
        let runtimePayload = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: cid,
            runID: UUID(),
            toolName: "delegate",
            originTrustLevel: SubAgentTrustLevel.system.rawValue,
            toolCallID: "tool-1",
            source: "tests"
        )
        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: runtimePayload),
            runID: UUID(),
            modelCallId: nil
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let eventData = try #require(collector.lines.last?.data(using: .utf8))
        let event = try decoder.decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: eventData)
        #expect(event.topic == topic)
        #expect(event.trustClass == .trusted)
        #expect(event.originTrust == .system)
    }

    @Test func orchestrationSemanticRemovedFromConversationEventsPayload() throws {
        #expect(ConversationTopicEventPayload.SemanticKind(rawValue: "orchestration") == nil)
    }

    @Test func messagesWireJSONArrayNormalizedMatchesMessagesRefreshWithoutTranscriptSeq() throws {
        let now = Date()
        let uid = UUID()
        let messages = [
            Message(id: uid, role: .user, content: "hello", timestamp: now, toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "hi", timestamp: now.addingTimeInterval(1), toolCalls: []),
        ]
        let arrayWire = ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: messages)
        let refreshWire = ConversationTopicWireEncoding.messagesRefreshJSONUTF8(from: messages, latestTranscriptSequence: nil)
        let canonicalArray = try Self.canonicalJSONUTF8(for: arrayWire)
        let canonicalRefresh = try Self.canonicalJSONUTF8(for: refreshWire)
        #expect(canonicalArray == canonicalRefresh)
        try Self.assertMessagesDecodedEquivalent(fromJSONWire: arrayWire, originals: messages)
        try Self.assertMessagesDecodedEquivalent(fromJSONWire: refreshWire, originals: messages)
    }

    @Test func messagesWireRefreshWithSeqEmbedsEquivalentJSONArray() throws {
        let now = Date()
        let messages = [Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])]
        let expectedRowsUTF8 = ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: messages)
        let wrappedUTF8 = ConversationTopicWireEncoding.messagesRefreshJSONUTF8(from: messages, latestTranscriptSequence: 42)
        let wrappedData = try #require(wrappedUTF8.data(using: .utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: wrappedData) as? [String: Any])
        let seq = try #require(obj["latestTranscriptSequence"] as? Int)
        #expect(seq == 42)
        let rowsSerialized = try JSONSerialization.data(
            withJSONObject: try #require(obj["messages"] as Any),
            options: [.sortedKeys]
        )
        let rowsString = try #require(String(data: rowsSerialized, encoding: .utf8))
        let canonicalRows = try Self.canonicalJSONUTF8(for: rowsString)
        let canonicalExpectedRows = try Self.canonicalJSONUTF8(for: expectedRowsUTF8)
        #expect(canonicalRows == canonicalExpectedRows)
        try Self.assertMessagesDecodedEquivalent(fromJSONWire: rowsString, originals: messages)
    }

    /// Embedded `messages` in `GET /api/conversations/{id}` uses `[Message]` `Codable`; wire uses `toJSON` rows (extra null keys possible). Align on decoded semantics.
    @Test func projectedMessagesCodableDecodingMatchesHarnessWireDecoding() throws {
        let now = Date()
        let messages = [
            Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a", timestamp: now.addingTimeInterval(1), toolCalls: []),
        ]
        let wireUTF8 = ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: messages)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let codableData = try enc.encode(messages)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let codableDecoded = try decoder.decode([Message].self, from: codableData)
        let wireDecoded = try Self.harnessMessages(fromJSONArrayWire: wireUTF8)
        #expect(codableDecoded.count == wireDecoded.count)
        for (codableWire, decodedWireRows) in zip(codableDecoded, wireDecoded) {
            #expect(codableWire.id == decodedWireRows.id)
            #expect(codableWire.role == decodedWireRows.role)
            #expect(codableWire.content == decodedWireRows.content)
        }
    }

    @Test func checkpointCompactionRoundTripsThroughPayloadJSON() throws {
        let cid = UUID()
        let covered = [SessionEntryID.generate(), SessionEntryID.generate()]
        let tail = covered.last!
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: cid,
            harnessCheckpointKind: HarnessCheckpointWireKind.contextCompaction.rawValue,
            compactionCheckpointKind: "summarized",
            coveredRawMessageIDs: covered,
            basedOnTailMessageID: tail,
            invalidatedCheckpointKinds: nil
        )
        let payload = ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire)
        #expect(payload.semanticKind == .checkpoint)
        let outer = try JSONEncoder().encode(payload)
        let decodedOuter = try JSONDecoder().decode(ConversationTopicEventPayload.self, from: outer)
        #expect(decodedOuter.semanticKind == .checkpoint)
        let innerJSON = try #require(decodedOuter.jsonUTF8)
        let innerData = try #require(innerJSON.data(using: .utf8))
        let decodedWire = try JSONDecoder().decode(ConversationCheckpointTopicEventWire.self, from: innerData)
        #expect(decodedWire == wire)
    }

    @Test func checkpointInvalidationRoundTripsThroughPayloadJSON() throws {
        let cid = UUID()
        let wire = ConversationCheckpointTopicEventWire(
            variant: .checkpointInvalidation,
            conversationID: cid,
            invalidatedCheckpointKinds: ["context_compaction", "turn_summary_event"]
        )
        let payload = ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire)
        #expect(payload.semanticKind == .checkpoint)
        let outer = try JSONEncoder().encode(payload)
        let decodedOuter = try JSONDecoder().decode(ConversationTopicEventPayload.self, from: outer)
        let innerJSON = try #require(decodedOuter.jsonUTF8)
        let innerData = try #require(innerJSON.data(using: .utf8))
        let decodedWire = try JSONDecoder().decode(ConversationCheckpointTopicEventWire.self, from: innerData)
        #expect(decodedWire == wire)
    }

    @Test func checkpointSeqTrackedOnPersistedBroadcast() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let wire = ConversationCheckpointTopicEventWire(
            variant: .checkpointInvalidation,
            conversationID: cid,
            invalidatedCheckpointKinds: ["context_compaction"]
        )
        await hub.broadcastPersisted(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire),
            transcriptSequence: 4
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 4)
        #expect(await hub.currentCheckpointSeq(forConversationID: cid) == 4)
        #expect(await hub.currentMessageSeq(forConversationID: cid) == 0)
    }

    @Test func runtimeLifecycleTransientOrdinalsMonotonicPerRun() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let runID = UUID()
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerConnection { line in
            collector.lines.append(line.json)
        }
        try await hub.subscribe(
            token: token,
            conversationID: cid,
            since: nil,
            transcriptReplay: .empty,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 0
        )
        let names: [RuntimeLifecycleEventName] = [
            .turnStarted,
            .loopIterationStarted,
            .modelCallStarted,
        ]
        for name in names {
            let lifecycle = RuntimeLifecycleEventPayload(
                name: name,
                conversationID: cid,
                runID: runID,
                iteration: name == .turnStarted ? nil : 1
            )
            await hub.broadcastTransient(
                conversationID: cid,
                payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: lifecycle),
                runID: runID,
                modelCallId: nil
            )
        }
        #expect(collector.lines.count == 1 + names.count)
        for (i, _) in names.enumerated() {
            let data = try #require(collector.lines[1 + i].data(using: .utf8))
            let msg = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: data)
            #expect(msg.seq == i + 1)
            #expect(msg.runId == runID)
            #expect(msg.turnOrdinal == i + 1)
        }
    }

    @Test func runtimeLifecycleToolEventsHaveTransientOrdinals() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let runID = UUID()
        let started = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: cid,
            runID: runID,
            iteration: 1,
            toolName: "get_plan",
            toolCallID: "call-1"
        )
        let completed = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: cid,
            runID: runID,
            iteration: 1,
            toolName: "get_plan",
            toolCallID: "call-1"
        )
        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: started),
            runID: runID,
            modelCallId: nil
        )
        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: completed),
            runID: runID,
            modelCallId: nil
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 2)
    }

    @Test func modelLifecycleEventRoundTripsThroughPayloadJSON() throws {
        let pool = ModelStatePayload(
            phase: .connecting,
            thinking: false,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 0),
            inFlightCount: 2
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inner = try encoder.encode(pool)
        let innerString = try #require(String(data: inner, encoding: .utf8))
        let payload = ConversationTopicEventPayload.modelLifecycleJSONUTF8(innerString)
        #expect(payload.semanticKind == .modelLifecycle)
        let outer = try JSONEncoder().encode(payload)
        let decodedOuter = try JSONDecoder().decode(ConversationTopicEventPayload.self, from: outer)
        #expect(decodedOuter.semanticKind == .modelLifecycle)
        let innerJSON = try #require(decodedOuter.jsonUTF8)
        let innerData = try #require(innerJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPool = try decoder.decode(ModelStatePayload.self, from: innerData)
        #expect(decodedPool == pool)
    }

    @Test func runtimeLifecycleEventRoundTripsThroughPayloadJSON() throws {
        let payload = RuntimeLifecycleEventPayload(
            name: .loopIterationStarted,
            conversationID: UUID(),
            runID: UUID(),
            iteration: 2,
            modelID: UUID(),
            source: "runtime"
        )
        let wire = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: payload)
        #expect(wire.semanticKind == .runtimeLifecycle)
        let outer = try JSONEncoder().encode(wire)
        let decodedOuter = try JSONDecoder().decode(ConversationTopicEventPayload.self, from: outer)
        #expect(decodedOuter.semanticKind == .runtimeLifecycle)
        let innerJSON = try #require(decodedOuter.jsonUTF8)
        let innerData = try #require(innerJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPayload = try decoder.decode(RuntimeLifecycleEventPayload.self, from: innerData)
        #expect(decodedPayload.schemaVersion == RuntimeLifecycleEventPayload.schemaVersionV1)
        #expect(decodedPayload.name == .loopIterationStarted)
        #expect(decodedPayload.iteration == 2)
        #expect(decodedPayload.source == "runtime")
    }

    @Test func runtimeLifecycleToolUsageSummaryValidatesContract() throws {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: UUID(),
            runID: UUID(),
            toolCount: 3,
            toolNames: ["web_search", "web_fetch"],
            summaryText: "Completed 3 tool calls",
            source: "runtime.summary"
        )
        let wire = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: payload)
        #expect(PublishingContractValidator.validateConversationEventPayload(wire).isEmpty)
    }

    @Test func runtimeLifecycleToolUsageSummaryRejectsMissingToolNames() throws {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: UUID(),
            runID: UUID(),
            toolCount: 2,
            toolNames: [],
            source: "runtime.summary"
        )
        let wire = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: payload)
        let issues = PublishingContractValidator.validateConversationEventPayload(wire)
        #expect(issues.contains(where: { $0.contains("tool.usageSummary requires non-empty toolNames") }))
    }

    @Test func hasSubscribersFalseUntilSubscribe() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        #expect(await hub.hasSubscribers(forConversationID: cid) == false)
        let token = await hub.registerConnection { _ in }
        try await hub.subscribe(
            token: token,
            conversationID: cid,
            since: nil,
            transcriptReplay: .empty,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 0
        )
        #expect(await hub.hasSubscribers(forConversationID: cid) == true)
    }

    @Test func subscribeForwardsPersistedReplayLinesBeforeSnapshot() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let replayPayload = ConversationTopicWireEncoding.messagesRefreshPayload(messages: [], latestTranscriptSequence: 1)
        let line = try Self.encodePersistedEventLine(
            topic: topic,
            seq: 1,
            payload: replayPayload,
            messageSeq: 1,
            checkpointSeq: nil
        )
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 1,
            latestMessage: 1,
            latestCheckpoint: 0,
            persistedReplayLines: [line]
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
            conversationID: cid,
            since: 0,
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 1
        )

        #expect(collector.lines.count == 2)
        let replayData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.seq == 1)
        #expect(replay.messageSeq == 1)
        #expect(replay.checkpointSeq == nil)

        let snapData = try #require(collector.lines.last?.data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 1)
    }

    @Test func subscribeDropsInvalidPersistedReplayLineBySchema() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let invalidLine = #"{"kind":"event","topic":"\#(topic)","seq":1,"value":{"semanticKind":"streamDone"}}"#
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 1,
            latestMessage: 1,
            latestCheckpoint: 0,
            persistedReplayLines: [invalidLine]
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
            conversationID: cid,
            since: 0,
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 1
        )

        #expect(collector.lines.count == 1)
        let snapData = try #require(collector.lines.first?.data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
    }

    @Test func subscribeSkipsLaggingWhenLegacySinceAheadOfStoreHead() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 2,
            latestMessage: 2,
            latestCheckpoint: 0,
            persistedReplayLines: []
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
            conversationID: cid,
            since: 5,
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 2
        )

        #expect(collector.lines.count == 1)
        let snapData = try #require(collector.lines.first?.data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.topic == topic)
        #expect(snap.seq == 2)
    }

    @Test func inProcessSubscribeReceivesSnapshotAndTransientEvents() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        final class LineCollector: @unchecked Sendable {
            var lines: [String] = []
        }
        let collector = LineCollector()
        let token = await hub.registerInProcessSubscriber { json in
            collector.lines.append(json)
        }

        await hub.subscribeInProcess(
            token: token,
            conversationID: cid,
            since: nil,
            transcriptReplay: .empty,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 0
        )

        await hub.broadcastTransient(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "hello"),
            runID: UUID(),
            modelCallId: nil
        )

        #expect(collector.lines.count == 2)
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let eventData = try #require(collector.lines[1].data(using: .utf8))
        let event = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: eventData)
        #expect(event.kind == .event)
    }

    @Test func dualSubscribeOmitsCheckpointReplayWhenBundleHasOnlyMessageLine() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let mPayload = ConversationTopicWireEncoding.messagesRefreshPayload(messages: [], latestTranscriptSequence: 2)
        let line = try Self.encodePersistedEventLine(
            topic: topic,
            seq: 1,
            payload: mPayload,
            messageSeq: 1,
            checkpointSeq: nil
        )
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 2,
            latestMessage: 1,
            latestCheckpoint: 1,
            persistedReplayLines: [line]
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
            conversationID: cid,
            replay: .dual(sinceMessage: 0, sinceCheckpoint: nil),
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 2
        )

        #expect(collector.lines.count == 2)
        let replayData = try #require(collector.lines.first?.data(using: .utf8))
        let replay = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: replayData)
        #expect(replay.kind == .event)
        #expect(replay.messageSeq == 1)
        #expect(replay.seq == 1)
    }

    @Test func dualSubscribeReplaysMessageAndCheckpointInTotalOrder() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let mPayload = ConversationTopicWireEncoding.messagesRefreshPayload(messages: [], latestTranscriptSequence: 3)
        let l1 = try Self.encodePersistedEventLine(topic: topic, seq: 1, payload: mPayload, messageSeq: 1, checkpointSeq: nil)
        let chkWire = ConversationCheckpointTopicEventWire(
            variant: .checkpointInvalidation,
            conversationID: cid,
            invalidatedCheckpointKinds: ["context_compaction"]
        )
        let p2 = ConversationTopicWireEncoding.checkpointTopicPayload(wire: chkWire)
        let l2 = try Self.encodePersistedEventLine(topic: topic, seq: 2, payload: p2, messageSeq: nil, checkpointSeq: 2)
        let mPayloadB = ConversationTopicWireEncoding.messagesRefreshPayload(messages: [], latestTranscriptSequence: 3)
        let l3 = try Self.encodePersistedEventLine(topic: topic, seq: 3, payload: mPayloadB, messageSeq: 3, checkpointSeq: nil)
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 3,
            latestMessage: 3,
            latestCheckpoint: 2,
            persistedReplayLines: [l1, l2, l3]
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
            conversationID: cid,
            replay: .dual(sinceMessage: 0, sinceCheckpoint: 0),
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 3
        )

        #expect(collector.lines.count == 4)
        let d0 = try #require(collector.lines[0].data(using: .utf8))
        let e0 = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: d0)
        #expect(e0.seq == 1 && e0.messageSeq == 1)
        let d1 = try #require(collector.lines[1].data(using: .utf8))
        let e1 = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: d1)
        #expect(e1.seq == 2 && e1.checkpointSeq == 2)
        let d2 = try #require(collector.lines[2].data(using: .utf8))
        let e2 = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: d2)
        #expect(e2.seq == 3 && e2.messageSeq == 3)

        let snapData = try #require(collector.lines[3].data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        #expect(snap.seq == 3)
    }

    @Test func dualSubscribeSendsLaggingWhenCheckpointCursorAheadOfHead() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let topic = ConversationTopicFormat.topic(conversationID: cid)
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 4,
            latestMessage: 2,
            latestCheckpoint: 1,
            persistedReplayLines: []
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
            conversationID: cid,
            replay: .dual(sinceMessage: 0, sinceCheckpoint: 5),
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 4
        )

        #expect(collector.lines.count == 2)
        let lagData = try #require(collector.lines.first?.data(using: .utf8))
        let lag = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: lagData)
        #expect(lag.kind == .lagging)
        #expect(lag.topic == topic)
        #expect(lag.seq == 4)
    }

    @Test func subscribeHandshakeMintsResumeTokenWhenSecretConfigured() async throws {
        let secret = "test-resume-secret"
        let hub = ConversationEventsTopicHub(resumeTokenHMACSecret: secret)
        let cid = UUID()
        let bundle = ConversationTranscriptSubscribeReplay(
            latestTotal: 2,
            latestMessage: 2,
            latestCheckpoint: 1,
            persistedReplayLines: []
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
            conversationID: cid,
            replay: .dual(sinceMessage: 0, sinceCheckpoint: 0),
            transcriptReplay: bundle,
            snapshotMessagesJSONUTF8: { _ in "[]" },
            snapshotTranscriptSequence: 2
        )

        #expect(collector.lines.count == 1)
        let snapData = try #require(collector.lines[0].data(using: .utf8))
        let snap = try JSONDecoder().decode(CommResourceTopicMessage<ConversationTopicEventPayload>.self, from: snapData)
        #expect(snap.kind == .snapshot)
        let resume = try #require(snap.resumeToken)
        let decoded = try ConversationEventsResumeToken.parse(resume, secret: Data(secret.utf8), conversationID: cid)
        #expect(decoded.msg == 2)
        #expect(decoded.chk == 1)
        #expect(decoded.tot == 2)
    }

    @Test func strictGovernanceRejectsInvalidEventPayloadWithoutSeqAdvance() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        await hub.broadcast(
            conversationID: cid,
            payload: .contentDeltaJSONUTF8("{not valid")
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsInvalidRuntimeLifecycleSchemaVersion() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            schemaVersion: RuntimeLifecycleEventPayload.schemaVersionV1 + 1,
            name: .turnStarted,
            conversationID: cid
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsInvalidRuntimeLifecycleIteration() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .loopIterationStarted,
            conversationID: cid,
            iteration: 0
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsRuntimeToolLifecycleWithoutToolName() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: cid,
            iteration: 1,
            toolName: nil
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsRuntimeToolLifecycleWithoutToolCallID() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write"
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsDigestWithoutRedactionTier() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolCallCompleted,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write",
            toolCallID: "call-1",
            argumentDigest: "abc123",
            resultDigest: "def456"
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsExecutionEnvironmentAdapterWithoutKind() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write",
            toolCallID: "call-1",
            executionEnvironmentAdapterID: "tool-env.local.default"
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsApprovalRequiredWithoutPendingState() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolApprovalRequired,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write",
            approvalState: .approved,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            approvalRoute: .user
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceRejectsApprovalResolvedWithoutSource() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let invalid = RuntimeLifecycleEventPayload(
            name: .toolApprovalResolved,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write",
            approvalState: .approved,
            approvalSource: nil,
            approvalRoute: .user
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: invalid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 0)
    }

    @Test func strictGovernanceAcceptsStructuredApprovalRequiredPayload() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .strict, diagnosticsEnabled: true)
        )
        let cid = UUID()
        let valid = RuntimeLifecycleEventPayload(
            name: .toolApprovalRequired,
            conversationID: cid,
            iteration: 1,
            toolName: "filesystem_write",
            approvalState: .pending,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            approvalRoute: .user,
            approvalTitle: "Tool Approval Required",
            approvalDescription: "Approve filesystem_write for this run (route: user).",
            approvalSeverity: "medium",
            approvalTimeoutMs: 120_000,
            approvalTimeoutBehavior: ToolPolicyConfiguration.ApprovalTimeoutBehavior.autoDeny.rawValue,
            approvalResolutionKind: ToolApprovalResolutionKind.runtimeAuto.rawValue,
            source: "runtime.toolPolicy"
        )
        await hub.broadcast(
            conversationID: cid,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: valid)
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 1)
    }

    @Test func runtimeLifecycleApprovalEventRoundTripsThroughPayloadJSON() throws {
        let payload = RuntimeLifecycleEventPayload(
            name: .toolApprovalResolved,
            conversationID: UUID(),
            runID: UUID(),
            iteration: 1,
            modelID: UUID(),
            toolName: "filesystem_write",
            approvalState: .approved,
            policyReason: "approvalRequired",
            approvalSource: "human.ui",
            approvalReason: "approved in test",
            approvalRoute: .user,
            source: "runtime.toolPolicy"
        )
        let wire = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: payload)
        #expect(wire.semanticKind == .runtimeLifecycle)
        let outer = try JSONEncoder().encode(wire)
        let decodedOuter = try JSONDecoder().decode(ConversationTopicEventPayload.self, from: outer)
        let innerJSON = try #require(decodedOuter.jsonUTF8)
        let innerData = try #require(innerJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPayload = try decoder.decode(RuntimeLifecycleEventPayload.self, from: innerData)
        #expect(decodedPayload.name == .toolApprovalResolved)
        #expect(decodedPayload.approvalState == .approved)
        #expect(decodedPayload.approvalSource == "human.ui")
        #expect(decodedPayload.toolName == "filesystem_write")
    }

    @Test func softGovernanceAllowsInvalidTransientPayloadWithWireSeqAdvance() async throws {
        let hub = ConversationEventsTopicHub(
            governance: PublishingGovernanceConfiguration(mode: .soft, diagnosticsEnabled: true)
        )
        let cid = UUID()
        await hub.broadcast(
            conversationID: cid,
            payload: .contentDeltaJSONUTF8("{not valid")
        )
        #expect(await hub.currentSeq(forConversationID: cid) == 1)
    }
}
