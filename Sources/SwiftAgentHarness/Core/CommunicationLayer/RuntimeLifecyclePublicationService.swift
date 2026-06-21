import CryptoKit
import Foundation

/// Trace span buffering, derived audit persistence, phase projection, and wire publication for runtime lifecycle events.
actor RuntimeLifecyclePublicationService {
    private let deps: ConversationRuntimeDependencies
    private let messaging: ConversationMessagingPort
    private let agentRuntime: any AgentRuntimeOrchestratorBinding
    private var traceTopicPublisher: (any TraceTopicPublishing)?
    private var conversationTopicPublisher: (any ConversationTopicPublishing)?
    private var traceSpansByConversationID: [UUID: [TraceSpanPayload]] = [:]
    private var serverTraceSpans: [TraceSpanPayload] = []
    private let maxTraceSpansPerConversation = 2_000
    private let maxServerTraceSpans = 5_000

    init(
        deps: ConversationRuntimeDependencies,
        messaging: ConversationMessagingPort,
        agentRuntime: any AgentRuntimeOrchestratorBinding
    ) {
        self.deps = deps
        self.messaging = messaging
        self.agentRuntime = agentRuntime
    }

    func setTraceTopicPublisher(_ publisher: (any TraceTopicPublishing)?) {
        traceTopicPublisher = publisher
    }

    func setConversationTopicPublisher(_ publisher: (any ConversationTopicPublishing)?) {
        conversationTopicPublisher = publisher
    }

    func publishRuntimeLifecycleEvent(_ payload: RuntimeLifecycleEventPayload) async {
        await publishRuntimeLifecycleWithFanout(payload)
    }

    func publishRuntimeLifecycleWithFanout(_ payload: RuntimeLifecycleEventPayload) async {
        if payload.name == .toolApprovalRequired || payload.name == .toolApprovalResolved {
            deps.logger?.debug(
                "[approval-trace] server fanout runtimeLifecycle name=\(payload.name.rawValue) conversationID=\(payload.conversationID.uuidString) runID=\(payload.runID?.uuidString ?? "nil") tool=\(payload.toolName ?? "nil") publisherConfigured=\(conversationTopicPublisher != nil)"
            )
        }
        await applyRuntimeLifecyclePhaseProjection(payload)
        let wirePayload = ConversationTopicWireEncoding.runtimeLifecyclePayload(payload: payload)
        await publishConversationTopicEventIfConfigured(
            conversationID: payload.conversationID,
            payload: wirePayload
        )
        await consumeRuntimeLifecycleEventForDerivedAudit(payload)
        await consumeRuntimeLifecycleEventForTrace(payload)
    }

    func consumeRuntimeLifecycleEventForTrace(_ payload: RuntimeLifecycleEventPayload) async {
        let span = traceSpanFromRuntimeLifecycle(payload)
        appendTraceSpan(span, conversationID: payload.conversationID)
        await publishTraceSpanIfConfigured(conversationID: payload.conversationID, span: span)
    }

    func consumeRuntimeLifecycleEventForDerivedAudit(_ payload: RuntimeLifecycleEventPayload) async {
        if payload.name == .toolUsageSummary {
            let toolCount = max(0, payload.toolCount ?? 0)
            let toolNames = (payload.toolNames ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let summary = ToolUsageSummaryEventPayload(
                runID: payload.runID,
                toolCount: toolCount,
                toolNames: toolNames,
                summaryText: payload.summaryText,
                source: payload.source,
                createdAt: payload.updatedAt
            )
            do {
                try await deps.persistenceDomain.routingPersistToolUsageSummaryEvent(
                    conversationID: payload.conversationID,
                    payload: summary
                )
            } catch {
                deps.logger?.warning("[RuntimeLifecyclePublicationService] Failed to persist tool usage summary event: \(error)")
            }
            return
        }
        let correlation = normalizedRuntimeToolCorrelation(from: payload)
        guard payload.name == .toolCallStarted
            || payload.name == .toolCallCompleted
            || payload.name == .toolCompletionAnnounced
            || payload.name == .toolApprovalRequired
            || payload.name == .toolApprovalResolved
            || payload.name == .toolElevatedExecuted
        else {
            return
        }
        guard let toolName = correlation.toolName else { return }
        let audit = ToolAuditLifecycleEventPayload(
            name: payload.name,
            runID: correlation.runID,
            iteration: payload.iteration,
            modelID: payload.modelID,
            toolName: toolName,
            delegateHandleID: correlation.delegateHandleID,
            toolCallID: correlation.toolCallID,
            completionAnnounceID: correlation.completionAnnounceID,
            usage: sanitizedCompletionUsage(payload.usage),
            approvalState: payload.approvalState,
            policyReason: payload.policyReason,
            approvalSource: payload.approvalSource,
            approvalReason: payload.approvalReason,
            argumentDigest: payload.argumentDigest,
            argumentByteCount: payload.argumentByteCount,
            argumentRedaction: payload.argumentRedaction,
            resultDigest: payload.resultDigest,
            resultByteCount: payload.resultByteCount,
            resultRedaction: payload.resultRedaction,
            resultTruncated: payload.resultTruncated,
            executionEnvironmentKind: payload.executionEnvironmentKind,
            executionEnvironmentAdapterID: payload.executionEnvironmentAdapterID,
            executionIsolationLevel: payload.executionIsolationLevel,
            source: payload.source,
            createdAt: payload.updatedAt
        )
        do {
            try await deps.persistenceDomain.routingPersistToolAuditLifecycleEvent(
                conversationID: payload.conversationID,
                payload: audit
            )
        } catch {
            deps.logger?.warning("[RuntimeLifecyclePublicationService] Failed to persist tool audit lifecycle event: \(error)")
        }
    }

    func traceSnapshotForConversation(conversationID: UUID) -> TraceTopicPayload {
        TraceTopicPayload(spans: traceSpansByConversationID[conversationID] ?? [])
    }

    func traceSnapshotForServer() -> TraceTopicPayload {
        TraceTopicPayload(spans: serverTraceSpans)
    }

    func listConversationTraces(conversationID: UUID, limit: Int?) -> ConversationTraceResponse {
        let all = traceSpansByConversationID[conversationID] ?? []
        let clipped: [TraceSpanPayload]
        if let limit {
            clipped = Array(all.suffix(max(0, limit)))
        } else {
            clipped = all
        }
        let updatedAt = clipped.last?.timestamp ?? Date()
        return ConversationTraceResponse(conversationID: conversationID, spans: clipped, updatedAt: updatedAt)
    }


    private func applyRuntimeLifecyclePhaseProjection(_ payload: RuntimeLifecycleEventPayload) async {
        guard var projectionSnapshot = await deps.persistenceDomain.modelConversation(id: payload.conversationID) else { return }
        if let payloadRunID = payload.runID,
           let existingRunID = projectionSnapshot.currentRunID,
           payloadRunID != existingRunID {
            return
        }
        if let payloadRunID = payload.runID {
            projectionSnapshot.currentRunID = payloadRunID
        }
        let didMutate: Bool
        switch payload.name {
        case .turnStarted:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .started
            projectionSnapshot.llmRequestPhase = .queued
            didMutate = true
        case .modelCallStarted:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .llmCall
            projectionSnapshot.llmRequestPhase = .generating
            didMutate = true
        case .modelCallCompleted:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .llmGenerationCompleted
            projectionSnapshot.llmRequestPhase = .queued
            didMutate = true
        case .toolApprovalRequired:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .waitingForToolExecution
            projectionSnapshot.llmRequestPhase = .queued
            didMutate = true
        case .toolCallStarted:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .executingTools
            projectionSnapshot.llmRequestPhase = .active
            didMutate = true
        case .toolCallCompleted, .toolCompletionAnnounced, .loopIterationCompleted:
            projectionSnapshot.state = .generating
            projectionSnapshot.agenticPhase = .betweenIterations
            projectionSnapshot.llmRequestPhase = .queued
            didMutate = true
        case .turnCompleted, .turnCancelled, .turnBounded:
            projectionSnapshot.state = .idle
            projectionSnapshot.agenticPhase = .idle
            projectionSnapshot.llmRequestPhase = .idle
            projectionSnapshot.currentRunID = nil
            didMutate = true
        case .loopIterationStarted, .toolUsageSummary, .toolApprovalResolved, .toolElevatedExecuted, .subagentOrphaned:
            didMutate = false
        }
        guard didMutate else { return }
        guard var latestConversation = await deps.persistenceDomain.modelConversation(id: payload.conversationID) else { return }
        if let payloadRunID = payload.runID,
           let existingRunID = latestConversation.currentRunID,
           payloadRunID != existingRunID {
            return
        }
        if latestConversation.messages.count != projectionSnapshot.messages.count {
            deps.logger?.debug(
                "[RuntimeLifecyclePublicationService] runtimeLifecycle projection merge preserving latest transcript conversationID=\(payload.conversationID.uuidString) payload=\(payload.name.rawValue) staleCount=\(projectionSnapshot.messages.count) latestCount=\(latestConversation.messages.count)"
            )
        }
        latestConversation.state = projectionSnapshot.state
        latestConversation.agenticPhase = projectionSnapshot.agenticPhase
        latestConversation.llmRequestPhase = projectionSnapshot.llmRequestPhase
        latestConversation.currentRunID = projectionSnapshot.currentRunID
        await messaging.update(conversation: latestConversation)
    }

    private func publishConversationTopicEventIfConfigured(
        conversationID: UUID,
        payload: ConversationTopicEventPayload
    ) async {
        guard let publisher = conversationTopicPublisher else { return }
        let lifecycle = await agentRuntime.lifecycleSnapshot(for: conversationID)
        let runID =
            await deps.persistenceDomain.modelConversation(id: conversationID)?.currentRunID
                ?? lifecycle.currentStreamingRunID
        let payloadSizeBytes = payload.jsonUTF8?.utf8.count ?? 0
        deps.logger?.debug(
            "[RuntimeLifecyclePublicationService] conversation-topic publish requested conversationID=\(conversationID.uuidString) semanticKind=\(payload.semanticKind.rawValue) runID=\(runID?.uuidString ?? "nil") payloadBytes=\(payloadSizeBytes)"
        )
        switch ConversationEventsReplayClassifier.stream(for: payload) {
        case .transient:
            let rid = runID ?? UUID()
            await publisher.publishTransientConversationEvent(
                conversationID: conversationID,
                payload: payload,
                runID: rid,
                modelCallId: nil
            )
        case .persistedMessage, .persistedCheckpoint:
            if let seq = try? await deps.persistenceDomain.latestTranscriptSequence(
                conversationID: conversationID
            ) {
                await publisher.publishPersistedConversationEvent(
                    conversationID: conversationID,
                    payload: payload,
                    transcriptSequence: seq
                )
            } else {
                await publisher.publishConversationEvent(conversationID: conversationID, payload: payload)
            }
        }
    }

    private struct RuntimeToolCorrelation: Sendable {
        let runID: UUID?
        let toolName: String?
        let toolCallID: String?
        let delegateHandleID: String?
        let completionAnnounceID: UUID?
    }

    private func normalizedRuntimeToolCorrelation(from payload: RuntimeLifecycleEventPayload) -> RuntimeToolCorrelation {
        RuntimeToolCorrelation(
            runID: payload.runID,
            toolName: normalizedRuntimeString(payload.toolName),
            toolCallID: normalizedRuntimeString(payload.toolCallID),
            delegateHandleID: normalizedRuntimeString(payload.delegateHandleID),
            completionAnnounceID: payload.completionAnnounceID
        )
    }

    private func normalizedRuntimeString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizedCompletionUsage(_ usage: DelegateCompletionUsagePayload?) -> DelegateCompletionUsagePayload? {
        guard let usage else { return nil }
        let promptTokens = max(0, usage.promptTokens ?? 0)
        let completionTokens = max(0, usage.completionTokens ?? 0)
        let providedTotal = max(0, usage.totalTokens ?? 0)
        let normalizedTotal = providedTotal > 0 ? providedTotal : max(0, promptTokens + completionTokens)
        let normalizedCost = max(0, usage.costUSD ?? 0)
        let hasSignal = promptTokens > 0 || completionTokens > 0 || normalizedTotal > 0 || normalizedCost > 0
        guard hasSignal else { return nil }
        return DelegateCompletionUsagePayload(
            promptTokens: promptTokens > 0 ? promptTokens : nil,
            completionTokens: completionTokens > 0 ? completionTokens : nil,
            totalTokens: normalizedTotal > 0 ? normalizedTotal : nil,
            costUSD: normalizedCost > 0 ? normalizedCost : nil
        )
    }

    private func traceSpanFromRuntimeLifecycle(_ payload: RuntimeLifecycleEventPayload) -> TraceSpanPayload {
        let correlation = normalizedRuntimeToolCorrelation(from: payload)
        var attributes: [String: String] = [:]
        attributes["eventName"] = payload.name.rawValue
        if let iteration = payload.iteration {
            attributes["iteration"] = "\(iteration)"
        }
        if let modelID = payload.modelID {
            attributes["modelID"] = modelID.uuidString.lowercased()
        }
        if let toolName = correlation.toolName {
            attributes["toolName"] = toolName
        }
        if let toolCallID = correlation.toolCallID {
            attributes["toolCallID"] = toolCallID
        }
        if let delegateHandleID = correlation.delegateHandleID {
            attributes["delegateHandleID"] = delegateHandleID
        }
        if let completionAnnounceID = correlation.completionAnnounceID {
            attributes["completionAnnounceID"] = completionAnnounceID.uuidString.lowercased()
        }
        if let promptTokens = payload.usage?.promptTokens {
            attributes["usage.promptTokens"] = "\(promptTokens)"
        }
        if let completionTokens = payload.usage?.completionTokens {
            attributes["usage.completionTokens"] = "\(completionTokens)"
        }
        if let totalTokens = payload.usage?.totalTokens {
            attributes["usage.totalTokens"] = "\(totalTokens)"
        }
        if let costUSD = payload.usage?.costUSD {
            attributes["usage.costUSD"] = String(format: "%.6f", costUSD)
        }
        if let argumentDigest = payload.argumentDigest, !argumentDigest.isEmpty {
            attributes["argumentDigest"] = argumentDigest
        }
        if let argumentByteCount = payload.argumentByteCount {
            attributes["argumentByteCount"] = "\(argumentByteCount)"
        }
        if let argumentRedaction = payload.argumentRedaction, !argumentRedaction.isEmpty {
            attributes["argumentRedaction"] = argumentRedaction
        }
        if let resultDigest = payload.resultDigest, !resultDigest.isEmpty {
            attributes["resultDigest"] = resultDigest
        }
        if let resultByteCount = payload.resultByteCount {
            attributes["resultByteCount"] = "\(resultByteCount)"
        }
        if let resultRedaction = payload.resultRedaction, !resultRedaction.isEmpty {
            attributes["resultRedaction"] = resultRedaction
        }
        if let resultTruncated = payload.resultTruncated {
            attributes["resultTruncated"] = resultTruncated ? "true" : "false"
        }
        if let executionEnvironmentKind = payload.executionEnvironmentKind, !executionEnvironmentKind.isEmpty {
            attributes["executionEnvironmentKind"] = executionEnvironmentKind
        }
        if let executionEnvironmentAdapterID = payload.executionEnvironmentAdapterID, !executionEnvironmentAdapterID.isEmpty {
            attributes["executionEnvironmentAdapterID"] = executionEnvironmentAdapterID
        }
        if let executionIsolationLevel = payload.executionIsolationLevel, !executionIsolationLevel.isEmpty {
            attributes["executionIsolationLevel"] = executionIsolationLevel
        }
        if let approvalState = payload.approvalState {
            attributes["approvalState"] = approvalState.rawValue
        }
        if let approvalRoute = payload.approvalRoute {
            attributes["approvalRoute"] = approvalRoute.rawValue
        }
        if let approvalSource = payload.approvalSource, !approvalSource.isEmpty {
            attributes["approvalSource"] = approvalSource
        }
        if let terminalReason = payload.terminalReason {
            attributes["terminalReasonCategory"] = terminalReason.category.rawValue
            if let bounded = terminalReason.boundedReason {
                attributes["terminalReasonBounded"] = bounded.rawValue
            }
            if let detail = terminalReason.detail, !detail.isEmpty {
                attributes["terminalReasonDetail"] = detail
            }
        }
        if let parentConversationID = payload.parentConversationID {
            attributes["parentConversationID"] = parentConversationID.uuidString.lowercased()
        }
        if let childConversationID = payload.childConversationID {
            attributes["childConversationID"] = childConversationID.uuidString.lowercased()
        }
        let traceID = payload.runID ?? payload.conversationID
        return TraceSpanPayload(
            traceID: traceID,
            name: payload.name.rawValue,
            category: "runtimeLifecycle",
            source: payload.source ?? "runtime",
            conversationID: payload.conversationID,
            runID: payload.runID,
            timestamp: payload.updatedAt,
            attributes: attributes.isEmpty ? nil : attributes
        )
    }

    private func appendTraceSpan(_ span: TraceSpanPayload, conversationID: UUID?) {
        if let conversationID {
            var rows = traceSpansByConversationID[conversationID] ?? []
            rows.append(span)
            if rows.count > maxTraceSpansPerConversation {
                rows.removeFirst(rows.count - maxTraceSpansPerConversation)
            }
            traceSpansByConversationID[conversationID] = rows
        }
        serverTraceSpans.append(span)
        if serverTraceSpans.count > maxServerTraceSpans {
            serverTraceSpans.removeFirst(serverTraceSpans.count - maxServerTraceSpans)
        }
    }

    private func publishTraceSpanIfConfigured(conversationID: UUID, span: TraceSpanPayload) async {
        guard let publisher = traceTopicPublisher else { return }
        let payload = TraceTopicPayload(spans: [span], updatedAt: span.timestamp)
        await publisher.publishConversationTrace(conversationID: conversationID, payload: payload)
        await publisher.publishServerTrace(payload: payload)
    }
}
