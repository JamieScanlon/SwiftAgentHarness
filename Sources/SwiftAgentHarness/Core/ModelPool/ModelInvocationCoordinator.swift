import Foundation
import SwiftAgentKit

/// Tracks per-model invocation lifecycle, derives ``thinking``, and publishes ``ModelStatePayload`` updates.
public actor ModelInvocationCoordinator: ModelInvocationLifecycleTracking {
    /// Per-call fan-out signature: invoked alongside ``publicationSink`` whenever a publish for a call
    /// whose ``beginCall(modelID:conversationID:)`` supplied a non-nil conversationID lands.
    public typealias ConversationLifecycleSink = @Sendable (
        _ conversationID: UUID,
        _ modelID: UUID,
        _ payload: ModelStatePayload
    ) async -> Void

    public typealias ModelCallsSink = @Sendable (
        _ modelID: UUID,
        _ payload: ModelCallsPayload
    ) async -> Void

    private var activeCallIDsByModel: [UUID: Set<UUID>] = [:]
    private var activeCallIDsByConversation: [UUID: Set<UUID>] = [:]
    private var activeCallIDsByLogicalRequest: [UUID: Set<UUID>] = [:]
    private var modelIDByCallID: [UUID: UUID] = [:]
    private var conversationIDByCallID: [UUID: UUID] = [:]
    private var logicalRequestIDByCallID: [UUID: UUID] = [:]
    private var rootCallIDByCallID: [UUID: UUID] = [:]
    private var rootCallIDByLogicalRequest: [UUID: UUID] = [:]
    private var callAttemptIndexByCallID: [UUID: Int] = [:]
    private var nextAttemptIndexByLogicalRequest: [UUID: Int] = [:]
    private var callAttemptRecordsByCallID: [UUID: [ModelCallRecord.AttemptRecord]] = [:]
    private var callStartedAtByCallID: [UUID: Date] = [:]
    private var callUpdatedAtByCallID: [UUID: Date] = [:]
    private var callEndedAtByCallID: [UUID: Date] = [:]
    private var latestCallIDByModel: [UUID: UUID] = [:]
    private var latestCallIDByConversation: [UUID: UUID] = [:]
    private var callPhaseByCallID: [UUID: ModelInvocationPhase] = [:]
    private var recentCallsByModel: [UUID: [UUID]] = [:]
    private let maxRecentCallsPerModel = 20
    private var latestPhase: [UUID: ModelInvocationPhase] = [:]
    private var announcedCallID: [UUID: UUID] = [:]
    private var connectingEnteredAt: [UUID: Date] = [:]
    private var streamingAccumulated: [UUID: String] = [:]
    private var streamingReasoningOnly: [UUID: Bool] = [:]
    private var connectingTasks: [UUID: Task<Void, Never>] = [:]
    private var latestInFlight: [UUID: Int] = [:]
    private var latestConcurrencyLimit: [UUID: Int] = [:]
    /// Wall-clock of the most recent terminal phase per model (`.done`/`.errored`/`.cancelled`).
    /// Surfaces on ``ModelStatePayload/lastCompletedAt`` so subscribers can render "x ago" without
    /// keeping their own latency history. Reset only on first observation; never cleared.
    private var lastCompletedAt: [UUID: Date] = [:]
    private enum PendingErrorKind: Sendable {
        case rateLimited
        case other
    }
    private var pendingErrorsByCallID: [UUID: PendingErrorKind] = [:]
    private var pendingCompletionTokensByCallID: [UUID: Int] = [:]

    private var publicationSink: (@Sendable (UUID, ModelStatePayload) async -> Void)?
    private var conversationPublicationSink: ConversationLifecycleSink?
    private var modelCallsSink: ModelCallsSink?
    private let communicationAggregates: CommunicationAggregatesEngine?

    private var lastEmitted: [UUID: ModelStatePayload] = [:]

    public init(
        publicationSink: (@Sendable (UUID, ModelStatePayload) async -> Void)? = nil,
        communicationAggregates: CommunicationAggregatesEngine? = nil
    ) {
        self.publicationSink = publicationSink
        self.communicationAggregates = communicationAggregates
    }

    /// Wire fan-out (typically ``ModelStateTopicHub``). Not retained by callers of ``snapshot(for:)``.
    public func setPublicationSink(_ sink: (@Sendable (UUID, ModelStatePayload) async -> Void)?) {
        publicationSink = sink
    }

    /// Conversation-scoped fan-out (typically conversation/{id}/events + state refresh). Receives every
    /// publish for which `activeConversationID[modelID]` is set.
    public func setConversationPublicationSink(_ sink: ConversationLifecycleSink?) {
        conversationPublicationSink = sink
    }

    /// Model-call stream fan-out (typically `model/{id}/calls` topic).
    public func setModelCallsSink(_ sink: ModelCallsSink?) {
        modelCallsSink = sink
    }

    public func beginCall(modelID: UUID, conversationID: UUID?, logicalRequestID: UUID?) async -> UUID {
        let id = UUID()
        let now = Date()
        let resolvedLogicalRequestID = logicalRequestID ?? id
        let attemptIndex = nextAttemptIndexByLogicalRequest[resolvedLogicalRequestID] ?? 1
        nextAttemptIndexByLogicalRequest[resolvedLogicalRequestID] = attemptIndex + 1
        let rootCallID = rootCallIDByLogicalRequest[resolvedLogicalRequestID] ?? id
        rootCallIDByLogicalRequest[resolvedLogicalRequestID] = rootCallID

        activeCallIDsByModel[modelID, default: []].insert(id)
        activeCallIDsByLogicalRequest[resolvedLogicalRequestID, default: []].insert(id)
        modelIDByCallID[id] = modelID
        logicalRequestIDByCallID[id] = resolvedLogicalRequestID
        rootCallIDByCallID[id] = rootCallID
        callAttemptIndexByCallID[id] = attemptIndex
        callStartedAtByCallID[id] = now
        callUpdatedAtByCallID[id] = now
        latestCallIDByModel[modelID] = id
        if let conversationID {
            conversationIDByCallID[id] = conversationID
            activeCallIDsByConversation[conversationID, default: []].insert(id)
            latestCallIDByConversation[conversationID] = id
        }
        callPhaseByCallID[id] = .queued
        callAttemptRecordsByCallID[id] = []
        appendRecentCall(id, modelID: modelID)
        streamingAccumulated[modelID] = ""
        streamingReasoningOnly[modelID] = false
        await communicationAggregates?.recordAttempt(modelID: modelID, callID: id)
        await publishCalls(modelID: modelID)
        return id
    }

    public func currentCallID(for modelID: UUID) async -> UUID? {
        latestActiveCallID(for: modelID)
    }

    /// Reverse lookup of the currently dispatched `(modelID, callID)` for a conversation, if any.
    /// Returns the first match in stable iteration order; in practice the coordinator only tracks
    /// a single active call per model, so collisions are limited to overlapping different-model
    /// calls on one conversation (legal during failover handoff). `nil` when no active call.
    public func activeCall(forConversationID conversationID: UUID) async -> (modelID: UUID, callID: UUID)? {
        guard let callID = latestCallIDByConversation[conversationID],
              let modelID = modelIDByCallID[callID],
              activeCallIDsByModel[modelID]?.contains(callID) == true
        else {
            return nil
        }
        return (modelID, callID)
    }

    public func endCall(modelID: UUID, callID: UUID) async {
        cancelConnectingTask(for: modelID)
        let endedAt = Date()
        callEndedAtByCallID[callID] = endedAt
        callUpdatedAtByCallID[callID] = endedAt
        activeCallIDsByModel[modelID]?.remove(callID)
        if activeCallIDsByModel[modelID]?.isEmpty == true {
            activeCallIDsByModel[modelID] = nil
        }
        if latestCallIDByModel[modelID] == callID {
            latestCallIDByModel[modelID] = latestActiveCallID(for: modelID)
        }
        if let conversationID = conversationIDByCallID[callID] {
            activeCallIDsByConversation[conversationID]?.remove(callID)
            if activeCallIDsByConversation[conversationID]?.isEmpty == true {
                activeCallIDsByConversation[conversationID] = nil
            }
            if latestCallIDByConversation[conversationID] == callID {
                latestCallIDByConversation[conversationID] = latestActiveCallID(forConversationID: conversationID)
            }
        }
        if let logicalRequestID = logicalRequestIDByCallID[callID] {
            activeCallIDsByLogicalRequest[logicalRequestID]?.remove(callID)
            if activeCallIDsByLogicalRequest[logicalRequestID]?.isEmpty == true {
                activeCallIDsByLogicalRequest[logicalRequestID] = nil
            }
        }
        streamingAccumulated[modelID] = nil
        streamingReasoningOnly[modelID] = nil
        connectingEnteredAt[modelID] = nil
        pendingErrorsByCallID.removeValue(forKey: callID)
        pendingCompletionTokensByCallID.removeValue(forKey: callID)
        callPhaseByCallID[callID] = .done
        await publishCalls(modelID: modelID)
    }

    /// Updates the cached per-model in-flight count (sourced from ``ModelCallScheduler``) and republishes
    /// `model/{id}/state` if the rendered payload changed.
    public func recordInFlight(modelID: UUID, count: Int, concurrencyLimit: Int? = nil) async {
        if count > 0 {
            latestInFlight[modelID] = count
            if let concurrencyLimit {
                latestConcurrencyLimit[modelID] = concurrencyLimit
            }
        } else {
            latestInFlight.removeValue(forKey: modelID)
            latestConcurrencyLimit.removeValue(forKey: modelID)
        }
        await publishIfPayloadChanged(modelID: modelID)
    }

    public func recordTransition(modelID: UUID, phase: ModelInvocationPhase, callID: UUID?) async {
        latestPhase[modelID] = phase
        let resolvedCallID = callID ?? latestActiveCallID(for: modelID)
        if let resolvedCallID {
            announcedCallID[modelID] = resolvedCallID
            callPhaseByCallID[resolvedCallID] = phase
            callUpdatedAtByCallID[resolvedCallID] = Date()
        }

        switch phase {
        case .connecting:
            connectingEnteredAt[modelID] = Date()
            await scheduleConnectingThinkingRefresh(modelID: modelID)
        default:
            connectingEnteredAt[modelID] = nil
            cancelConnectingTask(for: modelID)
        }

        if phase == .done || phase == .errored || phase == .cancelled {
            streamingAccumulated[modelID] = ""
            streamingReasoningOnly[modelID] = false
            lastCompletedAt[modelID] = Date()
            if let resolvedCallID {
                if phase == .done {
                    let completionTokens = pendingCompletionTokensByCallID.removeValue(forKey: resolvedCallID)
                    await communicationAggregates?.recordCompletion(
                        modelID: modelID,
                        callID: resolvedCallID,
                        completionTokens: completionTokens
                    )
                } else if phase == .errored {
                    let kind = pendingErrorsByCallID.removeValue(forKey: resolvedCallID)
                    await communicationAggregates?.recordFailure(
                        modelID: modelID,
                        callID: resolvedCallID,
                        rateLimited: kind == .rateLimited
                    )
                } else {
                    pendingErrorsByCallID.removeValue(forKey: resolvedCallID)
                    pendingCompletionTokensByCallID.removeValue(forKey: resolvedCallID)
                }
            }
        }

        await publish(modelID: modelID, callID: resolvedCallID)
        await publishCalls(modelID: modelID)
    }

    public func recordError(modelID: UUID, callID: UUID?, error: Error) async {
        guard let resolved = callID ?? latestActiveCallID(for: modelID) else { return }
        if TransientErrorClassifier.isRateLimited(error) {
            pendingErrorsByCallID[resolved] = .rateLimited
        } else {
            pendingErrorsByCallID[resolved] = .other
        }
    }

    public func recordResponseMetrics(modelID: UUID, callID: UUID?, response: LLMResponse) async {
        guard let resolved = callID ?? latestActiveCallID(for: modelID) else { return }
        let metadata = response.metadata
        let explicitTokens = metadata?.totalTokens
            ?? ((metadata?.promptTokens ?? 0) + (metadata?.completionTokens ?? 0))
        if explicitTokens > 0 {
            pendingCompletionTokensByCallID[resolved] = explicitTokens
            return
        }
        // Conservative fallback for providers that do not expose token usage yet.
        let estimatedTokens = max(0, response.content.count / 4)
        if estimatedTokens > 0 {
            pendingCompletionTokensByCallID[resolved] = estimatedTokens
        }
    }

    public func recordAttemptObservation(_ observation: ModelCallAttemptObservation) async {
        guard let callID = observation.callID ?? latestActiveCallID(for: observation.modelID) else { return }
        guard modelIDByCallID[callID] == observation.modelID else { return }
        let resolvedAttemptIndex: Int = {
            if let chainID = logicalRequestIDByCallID[callID] {
                let index = nextAttemptIndexByLogicalRequest[chainID] ?? 1
                nextAttemptIndexByLogicalRequest[chainID] = index + 1
                return index
            }
            let index = (callAttemptRecordsByCallID[callID]?.last?.attemptIndex ?? callAttemptIndexByCallID[callID] ?? 0) + 1
            return index
        }()
        let record = ModelCallRecord.AttemptRecord(
            attemptIndex: resolvedAttemptIndex,
            kind: observation.kind,
            outcome: observation.outcome,
            observedAt: observation.observedAt,
            providerID: observation.providerID,
            endpointModelID: observation.endpointModelID,
            targetModelID: observation.targetModelID,
            promptCacheMode: observation.promptCacheMode,
            promptCacheStablePrefixMessageCount: observation.promptCacheStablePrefixMessageCount,
            promptCacheProviderSupportsNative: observation.promptCacheProviderSupportsNative,
            promptCacheProviderApplied: observation.promptCacheProviderApplied,
            promptCacheEstimatedInputTokens: observation.promptCacheEstimatedInputTokens,
            promptCacheEstimatedCachedInputTokens: observation.promptCacheEstimatedCachedInputTokens,
            promptCacheEstimatedCacheWriteTokens: observation.promptCacheEstimatedCacheWriteTokens,
            promptCacheEstimatedSavingsUSD: observation.promptCacheEstimatedSavingsUSD,
            errorClass: observation.errorClass,
            errorCode: observation.errorCode,
            latencyMs: observation.latencyMs
        )
        var rows = callAttemptRecordsByCallID[callID] ?? []
        rows.append(record)
        callAttemptRecordsByCallID[callID] = rows
        callUpdatedAtByCallID[callID] = observation.observedAt
        await publishCalls(modelID: observation.modelID)
    }

    public func recordStreamPartial(modelID: UUID, callID: UUID?, partial: LLMResponse) async {
        guard let expected = callID ?? latestActiveCallID(for: modelID),
              activeCallIDsByModel[modelID]?.contains(expected) == true
        else {
            return
        }

        streamingAccumulated[modelID] = (streamingAccumulated[modelID] ?? "") + partial.content
        updateStreamingReasoningOnly(modelID: modelID, partial: partial)

        let prior = latestPhase[modelID]
        var next = prior ?? .streaming

        if !partial.toolCalls.isEmpty {
            next = .toolCalling
        } else if prior == .toolCalling {
            next = .streaming
        }

        if next != prior {
            latestPhase[modelID] = next
            await publish(modelID: modelID, callID: expected)
        } else {
            await publishIfPayloadChanged(modelID: modelID, callID: expected)
        }
    }

    public func scheduleConnectingThinkingRefresh(modelID: UUID) async {
        cancelConnectingTask(for: modelID)
        let task = Task { [modelID] in
            try? await Task.sleep(nanoseconds: 210_000_000)
            await self.refreshConnectingThinking(modelID: modelID)
        }
        connectingTasks[modelID] = task
    }

    private func refreshConnectingThinking(modelID: UUID) async {
        guard latestPhase[modelID] == .connecting else { return }
        await publishIfPayloadChanged(modelID: modelID)
    }

    /// Latest derived payload for WebSocket snapshot / tests.
    public func snapshot(for modelID: UUID) async -> ModelStatePayload {
        await buildPayload(modelID: modelID)
    }

    public func callsSnapshot(for modelID: UUID) async -> ModelCallsPayload {
        await buildCallsPayload(modelID: modelID)
    }

    public func latestPhase(for modelID: UUID) -> ModelInvocationPhase? {
        latestPhase[modelID]
    }

    private func buildPayload(modelID: UUID) async -> ModelStatePayload {
        let phase = latestPhase[modelID] ?? .done
        let callID = announcedCallID[modelID] ?? latestActiveCallID(for: modelID)
        let thinking = ModelStateDeriver.thinking(
            phase: phase,
            connectingEnteredAt: connectingEnteredAt[modelID],
            now: Date(),
            streamingAssistantContent: streamingAccumulated[modelID],
            streamingReasoningOnly: streamingReasoningOnly[modelID] ?? false
        )
        let aggregateSnapshot = await communicationAggregates?.snapshot(for: modelID) ?? ModelCommunicationAggregatesSnapshot()
        let inFlight = latestInFlight[modelID]
        let limit = latestConcurrencyLimit[modelID]
        let accepting: Bool?
        let status: ModelStatePayload.SchedulabilityStatus?
        if let inFlight, let limit {
            accepting = inFlight < limit
            status = inFlight >= limit ? .saturated : .accepting
        } else {
            accepting = nil
            status = nil
        }
        return ModelStatePayload(
            phase: phase,
            thinking: thinking,
            callId: callID,
            updatedAt: Date(),
            inFlightCount: inFlight,
            lastCompletedAt: lastCompletedAt[modelID],
            recentLatencyMsP50: aggregateSnapshot.recentLatencyMsP50,
            recentLatencyMsP95: aggregateSnapshot.recentLatencyMsP95,
            recentTokensPerSecond: aggregateSnapshot.recentTokensPerSecond,
            rateLimitWindow: aggregateSnapshot.rateLimitWindow,
            accepting: accepting,
            status: status,
            concurrencyActive: inFlight,
            concurrencyLimit: limit,
            errorRate1m: nil
        )
    }

    private func buildCallsPayload(modelID: UUID) async -> ModelCallsPayload {
        let activeCallIDs = activeCallIDsByModel[modelID] ?? []
        let active = activeCallIDs
            .sorted { lhs, rhs in
                (callStartedAtByCallID[lhs] ?? .distantPast) < (callStartedAtByCallID[rhs] ?? .distantPast)
            }
            .map { buildCallRecord(callID: $0) }
        let recent = (recentCallsByModel[modelID] ?? [])
            .reversed()
            .compactMap { callID -> ModelCallRecord? in
                guard !activeCallIDs.contains(callID) else { return nil }
                return buildCallRecord(callID: callID)
            }
        return ModelCallsPayload(modelID: modelID, active: active, recent: recent, updatedAt: Date())
    }

    private func buildCallRecord(callID: UUID) -> ModelCallRecord {
        ModelCallRecord(
            callID: callID,
            logicalRequestID: logicalRequestIDByCallID[callID],
            rootCallID: rootCallIDByCallID[callID],
            attemptIndex: callAttemptIndexByCallID[callID],
            conversationID: conversationIDByCallID[callID],
            phase: callPhaseByCallID[callID] ?? .done,
            startedAt: callStartedAtByCallID[callID] ?? Date(),
            updatedAt: callUpdatedAtByCallID[callID] ?? Date(),
            endedAt: callEndedAtByCallID[callID],
            attempts: callAttemptRecordsByCallID[callID] ?? []
        )
    }

    public func poolCommunicationAggregatesSnapshot() async -> PoolCommunicationAggregatesSnapshot {
        await communicationAggregates?.poolSnapshot() ?? PoolCommunicationAggregatesSnapshot()
    }

    private func publish(modelID: UUID, callID: UUID?) async {
        let payload = await buildPayload(modelID: modelID)
        lastEmitted[modelID] = payload
        await publicationSink?(modelID, payload)
        await fanOutToConversationSink(modelID: modelID, payload: payload, callID: callID)
    }

    private func publishIfPayloadChanged(modelID: UUID, callID: UUID? = nil) async {
        let payload = await buildPayload(modelID: modelID)
        guard lastEmitted[modelID] != payload else { return }
        lastEmitted[modelID] = payload
        await publicationSink?(modelID, payload)
        await fanOutToConversationSink(modelID: modelID, payload: payload, callID: callID)
    }

    private func fanOutToConversationSink(modelID: UUID, payload: ModelStatePayload, callID: UUID?) async {
        guard let sink = conversationPublicationSink else { return }
        if let callID,
           let conversationID = conversationIDByCallID[callID] {
            await sink(conversationID, modelID, payload)
            return
        }
        let conversationIDs = Set((activeCallIDsByModel[modelID] ?? []).compactMap { conversationIDByCallID[$0] })
        for conversationID in conversationIDs {
            await sink(conversationID, modelID, payload)
        }
    }

    private func publishCalls(modelID: UUID) async {
        guard let modelCallsSink else { return }
        let payload = await buildCallsPayload(modelID: modelID)
        await modelCallsSink(modelID, payload)
    }

    private func cancelConnectingTask(for modelID: UUID) {
        connectingTasks[modelID]?.cancel()
        connectingTasks[modelID] = nil
    }

    private func latestActiveCallID(for modelID: UUID) -> UUID? {
        (activeCallIDsByModel[modelID] ?? []).max { lhs, rhs in
            (callUpdatedAtByCallID[lhs] ?? .distantPast) < (callUpdatedAtByCallID[rhs] ?? .distantPast)
        }
    }

    private func latestActiveCallID(forConversationID conversationID: UUID) -> UUID? {
        (activeCallIDsByConversation[conversationID] ?? []).max { lhs, rhs in
            (callUpdatedAtByCallID[lhs] ?? .distantPast) < (callUpdatedAtByCallID[rhs] ?? .distantPast)
        }
    }

    private func appendRecentCall(_ callID: UUID, modelID: UUID) {
        var rows = recentCallsByModel[modelID] ?? []
        rows.removeAll { $0 == callID }
        rows.append(callID)
        if rows.count > maxRecentCallsPerModel {
            rows.removeFirst(rows.count - maxRecentCallsPerModel)
        }
        recentCallsByModel[modelID] = rows
    }

    private func updateStreamingReasoningOnly(modelID: UUID, partial: LLMResponse) {
        let accumulated = streamingAccumulated[modelID] ?? ""
        let visible = ModelStateDeriver.visibleAssistantContent(from: accumulated)
        if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            streamingReasoningOnly[modelID] = false
            return
        }
        if case .reasoning(let text) = partial.streamingFragment,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            streamingReasoningOnly[modelID] = true
        }
    }
}
