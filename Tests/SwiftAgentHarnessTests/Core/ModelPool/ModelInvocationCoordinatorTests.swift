import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor PhasePayloadCollector {
    var tuples: [(UUID, ModelStatePayload)] = []
    var phases: [ModelInvocationPhase] = []

    func appendTuple(_ item: (UUID, ModelStatePayload)) {
        tuples.append(item)
    }

    func appendPhase(_ p: ModelInvocationPhase) {
        phases.append(p)
    }
}

private actor ConversationSinkCollector {
    var tuples: [(UUID, UUID, ModelStatePayload)] = []

    func append(_ item: (UUID, UUID, ModelStatePayload)) {
        tuples.append(item)
    }
}

@Suite("ModelInvocationCoordinator")
struct ModelInvocationCoordinatorTests {
    @Test("snapshot includes communication aggregate latency and rate-limit hints")
    func snapshotIncludesCommunicationAggregates() async throws {
        final class Clock: @unchecked Sendable {
            var now: Date
            init(now: Date) { self.now = now }
        }
        let clock = Clock(now: Date(timeIntervalSince1970: 0))
        let aggregates = CommunicationAggregatesEngine(
            now: { clock.now },
            maxAttemptSamples: 16,
            maxLatencySamples: 16,
            rateLimitWindowSeconds: 60
        )
        let coordinator = ModelInvocationCoordinator(communicationAggregates: aggregates)
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        clock.now = Date(timeIntervalSince1970: 0.15)
        await coordinator.recordError(modelID: modelID, callID: callID, error: LLMError.rateLimitExceeded)
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callID)
        let snap = await coordinator.snapshot(for: modelID)
        #expect(snap.recentLatencyMsP50 != nil)
        #expect(snap.recentLatencyMsP95 != nil)
        #expect(snap.rateLimitWindow?.active == true)
    }

    @Test("Publication sink receives payload on phase transition")
    func publishesOnTransition() async throws {
        let collector = PhasePayloadCollector()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await collector.appendTuple((modelID, payload))
        }
        let modelID = UUID()
        let callID = UUID()
        await coordinator.recordTransition(modelID: modelID, phase: .queued, callID: callID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
        let tuples = await collector.tuples
        #expect(tuples.count == 2)
        #expect(tuples[0].1.phase == .queued)
        #expect(tuples[1].1.phase == .done)
    }

    @Test("Stream partial updates toolCalling phase when tool calls present")
    func toolCallingFromPartial() async throws {
        let collector = PhasePayloadCollector()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await collector.appendPhase(payload.phase)
        }
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        let partial = LLMResponse(content: "", toolCalls: [ToolCall(name: "t", arguments: .object([:]), id: "1")])
        await coordinator.recordStreamPartial(modelID: modelID, callID: callID, partial: partial)
        let phases = await collector.phases
        #expect(phases.contains(.toolCalling))
    }

    @Test("recordInFlight republishes with updated count")
    func recordInFlightRepublishes() async throws {
        let collector = PhasePayloadCollector()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await collector.appendTuple((modelID, payload))
        }
        let modelID = UUID()
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: UUID())
        await coordinator.recordInFlight(modelID: modelID, count: 1)
        await coordinator.recordInFlight(modelID: modelID, count: 2)
        await coordinator.recordInFlight(modelID: modelID, count: 0)
        let tuples = await collector.tuples
        let counts = tuples.map { $0.1.inFlightCount }
        #expect(counts.contains(1))
        #expect(counts.contains(2))
        // After recording count==0 the cached entry is cleared, so the latest payload reports nil.
        let lastPayload = try #require(tuples.last?.1)
        #expect(lastPayload.inFlightCount == nil)
    }

    @Test("inFlightCount is omitted (nil) until recordInFlight is called")
    func inFlightCountStartsNil() async throws {
        let collector = PhasePayloadCollector()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await collector.appendTuple((modelID, payload))
        }
        let modelID = UUID()
        await coordinator.recordTransition(modelID: modelID, phase: .queued, callID: UUID())
        let tuples = await collector.tuples
        #expect(tuples.count == 1)
        #expect(tuples[0].1.inFlightCount == nil)
    }

    @Test("recordInFlight with concurrencyLimit drives schedulability status")
    func recordInFlightConcurrencyLimit() async throws {
        let collector = PhasePayloadCollector()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await collector.appendTuple((modelID, payload))
        }
        let modelID = UUID()
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: UUID())
        await coordinator.recordInFlight(modelID: modelID, count: 3, concurrencyLimit: 3)
        let tuples = await collector.tuples
        let payload = try #require(tuples.last?.1)
        #expect(payload.concurrencyLimit == 3)
        #expect(payload.inFlightCount == 3)
        #expect(payload.accepting == false)
        #expect(payload.status == .saturated)
    }

    @Test("Conversation sink fires for calls with conversationID")
    func conversationSinkFiresWithConversationID() async throws {
        let modelCollector = PhasePayloadCollector()
        let convoCollector = ConversationSinkCollector()
        let coordinator = ModelInvocationCoordinator { modelID, payload in
            await modelCollector.appendTuple((modelID, payload))
        }
        await coordinator.setConversationPublicationSink { cid, mid, payload in
            await convoCollector.append((cid, mid, payload))
        }
        let modelID = UUID()
        let conversationID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID, conversationID: conversationID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
        let convoTuples = await convoCollector.tuples
        #expect(convoTuples.count >= 2)
        #expect(convoTuples.allSatisfy { $0.0 == conversationID && $0.1 == modelID })
        #expect(convoTuples.contains { $0.2.phase == .streaming })
        #expect(convoTuples.contains { $0.2.phase == .done })
    }

    @Test("Conversation sink does not fire when conversationID is nil")
    func conversationSinkSilentWithoutConversationID() async throws {
        let convoCollector = ConversationSinkCollector()
        let coordinator = ModelInvocationCoordinator { _, _ in }
        await coordinator.setConversationPublicationSink { cid, mid, payload in
            await convoCollector.append((cid, mid, payload))
        }
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
        let convoTuples = await convoCollector.tuples
        #expect(convoTuples.isEmpty)
    }

    @Test("endCall clears active conversation context")
    func endCallClearsConversationContext() async throws {
        let convoCollector = ConversationSinkCollector()
        let coordinator = ModelInvocationCoordinator { _, _ in }
        await coordinator.setConversationPublicationSink { cid, mid, payload in
            await convoCollector.append((cid, mid, payload))
        }
        let modelID = UUID()
        let conversationID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID, conversationID: conversationID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        await coordinator.endCall(modelID: modelID, callID: callID)
        let countAfterEnd = await convoCollector.tuples.count
        // Subsequent transitions for the same model should not fan to the conversation sink
        // because endCall cleared activeConversationID[modelID].
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: nil)
        let countAfterStrayTransition = await convoCollector.tuples.count
        #expect(countAfterStrayTransition == countAfterEnd)
    }

    @Test("calls snapshot tracks multi-flight rows per model")
    func callsSnapshotTracksMultiFlightRows() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        let callA = await coordinator.beginCall(modelID: modelID, conversationID: conversationA)
        let callB = await coordinator.beginCall(modelID: modelID, conversationID: conversationB)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callA)
        await coordinator.recordTransition(modelID: modelID, phase: .connecting, callID: callB)

        let activeForA = await coordinator.activeCall(forConversationID: conversationA)
        #expect(activeForA?.modelID == modelID)
        #expect(activeForA?.callID == callA)

        let snapshot = await coordinator.callsSnapshot(for: modelID)
        #expect(snapshot.active.count == 2)
        #expect(snapshot.active.contains(where: { $0.callID == callA && $0.conversationID == conversationA }))
        #expect(snapshot.active.contains(where: { $0.callID == callB && $0.conversationID == conversationB }))
    }

    @Test("calls snapshot includes logical request and failover attempt metadata")
    func callsSnapshotIncludesAttemptObservability() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let logicalRequestID = UUID()

        let callA = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: logicalRequestID)
        await coordinator.recordAttemptObservation(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: callA,
                kind: .retry,
                outcome: .continued,
                errorClass: "transient",
                errorCode: "timeout",
                providerID: "provider-a",
                endpointModelID: "model-a"
            )
        )
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callA)
        await coordinator.endCall(modelID: modelID, callID: callA)

        let callB = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: logicalRequestID)
        await coordinator.recordAttemptObservation(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: callB,
                kind: .bindingFailover,
                outcome: .succeeded,
                providerID: "provider-b",
                endpointModelID: "model-b"
            )
        )
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callB)

        let snapshot = await coordinator.callsSnapshot(for: modelID)
        let active = try #require(snapshot.active.first(where: { $0.callID == callB }))
        #expect(active.logicalRequestID == logicalRequestID)
        #expect(active.rootCallID == callA)
        #expect(active.attemptIndex == 3)
        #expect(active.attempts.contains(where: { $0.kind == .bindingFailover && $0.outcome == .succeeded }))

        let recent = try #require(snapshot.recent.first(where: { $0.callID == callA }))
        #expect(recent.logicalRequestID == logicalRequestID)
        #expect(recent.rootCallID == callA)
        #expect(recent.attemptIndex == 1)
        let hasRetryTimeout = recent.attempts.contains { row in
            row.kind == .retry && row.errorCode == "timeout"
        }
        #expect(hasRetryTimeout)
    }

    @Test("calls snapshot includes prompt-cache telemetry fields")
    func callsSnapshotIncludesPromptCacheTelemetry() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: UUID())
        await coordinator.recordAttemptObservation(
            ModelCallAttemptObservation(
                modelID: modelID,
                callID: callID,
                kind: .promptCache,
                outcome: .observed,
                providerID: "lmstudio",
                endpointModelID: "llama",
                promptCacheMode: "persistent",
                promptCacheStablePrefixMessageCount: 3,
                promptCacheProviderSupportsNative: true,
                promptCacheProviderApplied: true,
                promptCacheEstimatedInputTokens: 900,
                promptCacheEstimatedCachedInputTokens: 300,
                promptCacheEstimatedCacheWriteTokens: 300,
                promptCacheEstimatedSavingsUSD: 0.0006,
                promptCacheValuesAreProviderReported: true,
                promptCacheUnexpectedCacheWrite: true
            )
        )
        let snapshot = await coordinator.callsSnapshot(for: modelID)
        let row = try #require(snapshot.active.first(where: { $0.callID == callID }))
        let hasPromptCacheAttempt = row.attempts.contains { attempt in
            attempt.kind == .promptCache &&
                attempt.outcome == .observed &&
                attempt.promptCacheMode == "persistent" &&
                attempt.promptCacheProviderApplied == true &&
                attempt.promptCacheEstimatedCachedInputTokens == 300 &&
                attempt.promptCacheValuesAreProviderReported == true &&
                attempt.promptCacheUnexpectedCacheWrite == true
        }
        #expect(hasPromptCacheAttempt)
    }

    @Test("Structured reasoning fragment with empty content yields thinking during streaming")
    func reasoningFragmentThinkingSignal() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        let reasoningPartial = LLMResponse.streamChunk("", streamingFragment: .reasoning("step one"))
        await coordinator.recordStreamPartial(modelID: modelID, callID: callID, partial: reasoningPartial)
        let snap = await coordinator.snapshot(for: modelID)
        #expect(snap.thinking == true)

        let textPartial = LLMResponse(content: "visible answer", toolCalls: [])
        await coordinator.recordStreamPartial(modelID: modelID, callID: callID, partial: textPartial)
        let afterText = await coordinator.snapshot(for: modelID)
        #expect(afterText.thinking == false)
    }

    @Test("evicted ended calls drop per-call metadata")
    func evictedEndedCallsDropMetadata() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let firstCallID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: firstCallID)
        await coordinator.endCall(modelID: modelID, callID: firstCallID)

        for _ in 0..<20 {
            let callID = await coordinator.beginCall(modelID: modelID)
            await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
            await coordinator.endCall(modelID: modelID, callID: callID)
        }

        #expect(await coordinator.hasRetainedCallMetadataForTesting(callID: firstCallID) == false)
        let snapshot = await coordinator.callsSnapshot(for: modelID)
        #expect(snapshot.recent.count == 20)
        #expect(snapshot.recent.contains(where: { $0.callID == firstCallID }) == false)
    }

    @Test("active call metadata retained when evicted from recent window")
    func activeCallProtectedFromEvictionPrune() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let activeCallID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: activeCallID)

        for _ in 0..<20 {
            let callID = await coordinator.beginCall(modelID: modelID)
            await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
            await coordinator.endCall(modelID: modelID, callID: callID)
        }

        #expect(await coordinator.hasRetainedCallMetadataForTesting(callID: activeCallID) == true)
        let snapshot = await coordinator.callsSnapshot(for: modelID)
        let active = try #require(snapshot.active.first(where: { $0.callID == activeCallID }))
        #expect(active.phase == .streaming)
        #expect(active.startedAt <= Date())
    }

    @Test("logical-request maps pruned after chain completes")
    func logicalRequestMapsPrunedAfterChainCompletes() async throws {
        let coordinator = ModelInvocationCoordinator { _, _ in }
        let modelID = UUID()
        let logicalRequestID = UUID()

        let callA = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: logicalRequestID)
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callA)
        await coordinator.endCall(modelID: modelID, callID: callA)

        let callB = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: logicalRequestID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callB)
        await coordinator.endCall(modelID: modelID, callID: callB)

        for _ in 0..<20 {
            let callID = await coordinator.beginCall(modelID: modelID)
            await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
            await coordinator.endCall(modelID: modelID, callID: callID)
        }

        let callC = await coordinator.beginCall(modelID: modelID, conversationID: nil, logicalRequestID: logicalRequestID)
        let snapshot = await coordinator.callsSnapshot(for: modelID)
        let active = try #require(snapshot.active.first(where: { $0.callID == callC }))
        #expect(active.attemptIndex == 1)
        #expect(active.rootCallID == callC)
    }
}
