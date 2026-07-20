import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState? {
        let isTerminal = await isTerminalSnapshot(conversationID: conversationID)
        let forceStreaming = await shouldForceStreamingPhases(conversationID: conversationID, isTerminal: isTerminal)
        let runtimeLifecycle = await currentLifecycleSnapshot(for: conversationID)
        deps.logger?.debug(
            "[AgentRuntimeSessionService] snapshotOrchestrationState conversationID=\(conversationID.uuidString) terminal=\(isTerminal) forceStreaming=\(forceStreaming) activeConversationID=\(runtimeLifecycle.activeStreamingConversationID?.uuidString ?? "nil") activeRunID=\(runtimeLifecycle.currentStreamingRunID?.uuidString ?? "nil") contentStreamingActive=\(runtimeLifecycle.isContentStreamingActive)"
        )
        guard var snapshot = await buildOrchestrationStateSnapshotFromSwiftAgentKit(
            forStreamingConversation: conversationID,
            isTerminalSnapshotAfterCompletion: isTerminal,
            forceStreamingPhases: forceStreaming
        ) else { return nil }
        if let last = lastTopicRefreshOrchestrationSnapshot(),
           last.currentRunID == snapshot.currentRunID {
            if let generation = last.orchestrationGeneration {
                snapshot.orchestrationGeneration = generation
            }
            if snapshot.isRegressiveOrchestrationWireSnapshot(comparedTo: last) {
                snapshot.llmRuntimePhase = last.llmRuntimePhase
                snapshot.llmRuntimeFailureDetail = last.llmRuntimeFailureDetail
                snapshot.agenticPhase = last.agenticPhase
                snapshot.llmRequestPhase = last.llmRequestPhase
            }
        }
        return snapshot
    }

    func buildOrchestrationStateSnapshotFromSwiftAgentKit(
        forStreamingConversation streamingConversationID: UUID,
        isTerminalSnapshotAfterCompletion: Bool = false,
        forceStreamingPhases: Bool = false
    ) async -> ConversationOrchestrationState? {
        let targetID = streamingConversationID
        let lifecycle = await currentLifecycleSnapshot(for: streamingConversationID)
        let liveOrchestrator = await orchestrationCore.orchestrator(for: streamingConversationID)
        let orchestratorForSnapshot: SwiftAgentKitOrchestrator?
        if isTerminalSnapshotAfterCompletion {
            orchestratorForSnapshot = nil
        } else {
            let canUseLiveOrchestrator =
                liveOrchestrator != nil &&
                lifecycle.currentStreamingRunID != nil &&
                lifecycle.activeStreamingConversationID == streamingConversationID
            orchestratorForSnapshot = canUseLiveOrchestrator ? liveOrchestrator : nil
        }
        guard let conv = await deps.persistenceDomain.modelConversation(id: targetID) else {
            return nil
        }
        let effectiveRunID: UUID?
        if orchestratorForSnapshot != nil {
            effectiveRunID = lifecycle.currentStreamingRunID ?? conv.currentRunID
        } else {
            effectiveRunID = conv.currentRunID
        }
        let tokenMetrics = await contextTokenMetricsForOrchestration(conversationID: streamingConversationID)
        let built = await OrchestrationSnapshotComposer.buildSnapshot(
            conversation: conv,
            orchestrator: orchestratorForSnapshot,
            lastContextLimitTokens: tokenMetrics.lastContextLimitTokens,
            lastRemainingContextTokens: tokenMetrics.lastRemainingContextTokens,
            lastPromptTokens: tokenMetrics.lastPromptTokens,
            currentRunID: effectiveRunID,
            forceStreamingPhases: forceStreamingPhases,
            logger: deps.logger
        )
        if let patch = built.patch, !isTerminalSnapshotAfterCompletion {
            var synced = conv
            synced.agenticPhase = patch.agenticPhase
            synced.llmRequestPhase = patch.llmRequestPhase
            await messaging.update(conversation: synced)
        }
        var snapshot = built.snapshot
        if isTerminalSnapshotAfterCompletion {
            snapshot.agenticPhase = .idle
            snapshot.llmRequestPhase = .idle
            snapshot.currentRunID = nil
        }
        if let terminal = pendingTerminalReasonForSnapshot(
            conversationID: streamingConversationID,
            runID: effectiveRunID
        ) {
            let supplement = HarnessOrchestrationSupplement(
                milestone: snapshot.harness?.milestone,
                terminationCategory: terminal.category.rawValue,
                terminationDetail: terminal.detail ?? terminal.boundedReason?.rawValue
            )
            snapshot.harness = supplement
        }
        return snapshot
    }

    func emitOrchestrationStateFromLiveSources(
        swiftAgentKitGeneration: UInt64? = nil,
        preferredConversationID: UUID? = nil
    ) async {
        let lifecycle = if let preferredConversationID {
            await currentLifecycleSnapshot(for: preferredConversationID)
        } else {
            await currentLifecycleSnapshot()
        }
        let selectedConversationID = await selection.currentConversationID()
        guard let streamConversationID =
            preferredConversationID ??
            lifecycle.activeStreamingConversationID ??
            selectedConversationID
        else { return }
        let isTerminal = await isTerminalSnapshot(conversationID: streamConversationID)
        let forceStreamingPhases = await shouldForceStreamingPhases(
            conversationID: streamConversationID,
            isTerminal: isTerminal
        )
        guard var snapshot = await buildOrchestrationStateSnapshotFromSwiftAgentKit(
            forStreamingConversation: streamConversationID,
            isTerminalSnapshotAfterCompletion: isTerminal,
            forceStreamingPhases: forceStreamingPhases
        ) else { return }
        if await orchestrationEmissionConversationID() != streamConversationID {
            setLastTopicRefreshOrchestrationSnapshot(nil)
        }
        await setOrchestrationEmissionConversationID(streamConversationID)
        snapshot.orchestrationGeneration = swiftAgentKitGeneration
        deps.logger?.debug(
            "[AgentRuntimeSessionService] emit orchestration snapshot conversationID=\(streamConversationID.uuidString) generation=\(snapshot.orchestrationGeneration.map(String.init) ?? "nil") llm=\(snapshot.llmRuntimePhase.rawValue) request=\(snapshot.llmRequestPhase?.rawValue ?? "nil") agentic=\(snapshot.agenticPhase.rawValue) runID=\(snapshot.currentRunID?.uuidString ?? "nil")"
        )
        yieldOrchestrationSnapshot(snapshot)
        if let refreshHandler = orchestrationStateTopicRefreshHandler() {
            let shouldRefreshTopic: Bool
            if let last = lastTopicRefreshOrchestrationSnapshot(),
               snapshot.hasSameWireOrchestrationPhases(as: last) {
                shouldRefreshTopic = false
            } else {
                shouldRefreshTopic = true
                setLastTopicRefreshOrchestrationSnapshot(snapshot)
            }
            if shouldRefreshTopic {
                deps.logger?.debug(
                    "[AgentRuntimeSessionService] refreshing conversation state topic conversationID=\(streamConversationID.uuidString)"
                )
                await refreshHandler(streamConversationID, snapshot)
            } else {
                deps.logger?.debug(
                    "[AgentRuntimeSessionService] skipping duplicate orchestration topic refresh conversationID=\(streamConversationID.uuidString) generation=\(snapshot.orchestrationGeneration.map(String.init) ?? "nil")"
                )
            }
        }
    }

    func recordContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) async {
        await orchestrationCore.applyLLMContextSnapshot(
            for: conversationID,
            from: response,
            requestConfig: requestConfig
        )
        if let meta = response.metadata {
            let input = meta.promptTokens.map { String($0) } ?? "nil"
            let output = meta.completionTokens.map { String($0) } ?? "nil"
            let total = meta.totalTokens.map { String($0) } ?? "nil"
            let window = meta.contextWindowTokens.map { String($0) } ?? "nil"
            let remaining = LLMTokenMetadataBuilder.effectiveRemainingContextTokens(from: meta).map { String($0) } ?? "nil"
            let limit = (meta.contextWindowTokens ?? requestConfig.maxTokens).map { String($0) } ?? "nil"
            deps.logger?.debug(
                "[AgentRuntimeSessionService] LLM context snapshot: promptTokens=\(input) completionTokens=\(output) totalTokens=\(total) contextWindowTokens=\(window) remainingContextTokens=\(remaining) effectiveLimit=\(limit) — per completed LLM request; totalTokens = prompt+completion this call only (not cumulative)"
            )
            await selection.persistResourceBudgetHintFromContextTokens(conversationID: conversationID)
        } else {
            let cfgLimit = requestConfig.maxTokens.map { String($0) } ?? "nil"
            deps.logger?.debug(
                "[AgentRuntimeSessionService] LLM context snapshot: no response.metadata; input/output/remaining unknown; config.maxTokens=\(cfgLimit)"
            )
        }
        await emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)
    }

    func recordContextSnapshot(from response: LLMResponse, requestConfig: LLMRequestConfig) async {
        let lifecycle = await currentLifecycleSnapshot(for: nil)
        let conversationID = ConversationScope.current?.selfID ?? lifecycle.activeStreamingConversationID
        guard let conversationID else { return }
        await recordContextSnapshot(for: conversationID, from: response, requestConfig: requestConfig)
    }

    private func isTerminalSnapshot(conversationID: UUID) async -> Bool {
        let runtimeLifecycle = await currentLifecycleSnapshot(for: conversationID)
        if let runID = runtimeLifecycle.currentStreamingRunID,
           pendingTerminalReasonForSnapshot(conversationID: conversationID, runID: runID) != nil {
            return true
        }
        let hasActiveRunForConversation =
            runtimeLifecycle.activeStreamingConversationID == conversationID &&
            runtimeLifecycle.currentStreamingRunID != nil
        guard hasActiveRunForConversation else { return true }
        let runStillExecuting = runtimeLifecycle.generationTask != nil || runtimeLifecycle.isContentStreamingActive
        return !runStillExecuting
    }

    private func shouldForceStreamingPhases(conversationID: UUID, isTerminal: Bool) async -> Bool {
        guard !isTerminal else { return false }
        let runtimeLifecycle = await currentLifecycleSnapshot(for: conversationID)
        let isStreamingThisConversation =
            runtimeLifecycle.activeStreamingConversationID == conversationID &&
            runtimeLifecycle.currentStreamingRunID != nil
        return isStreamingThisConversation && runtimeLifecycle.isContentStreamingActive
    }
}
