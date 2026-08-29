import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func tokenSnapshotsForOrchestration() async -> (lastPromptTokens: Int?, lastContextLimitTokens: Int?) {
        await orchestrationCore.tokenSnapshotsForOrchestration(conversationID: nil)
    }

    func tokenSnapshotsForOrchestration(for conversationID: UUID) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?
    ) {
        await orchestrationCore.tokenSnapshotsForOrchestration(for: conversationID)
    }

    func lastModelRequestAt(for conversationID: UUID) async -> Date? {
        await orchestrationCore.lastModelRequestAt(for: conversationID)
    }

    func contextTokenMetricsForOrchestration(conversationID: UUID? = nil) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?,
        lastRemainingContextTokens: Int?
    ) {
        await orchestrationCore.contextTokenMetricsForOrchestration(conversationID: conversationID)
    }

    func resetContextTokenSnapshot() async {
        await orchestrationCore.resetTokenSnapshot()
    }

    func setContentStreamingActivity(isActive: Bool, conversationID: UUID, runID: UUID?) async {
        let lifecycle = await currentLifecycleSnapshot(for: conversationID)
        guard lifecycle.activeStreamingConversationID == conversationID else { return }
        if let runID, let activeRunID = lifecycle.currentStreamingRunID, runID != activeRunID { return }
        await updateLifecycle(for: conversationID) { $0.isContentStreamingActive = isActive }
    }

    func markStreamingGenerationCompleteIfCurrent(
        token: UInt64,
        terminalStatus: ConversationRunWireStatus? = nil,
        terminalReason: ConversationRunTerminalReason? = nil,
        markerKind: String? = nil,
        conversationID: UUID? = nil,
        runID: UUID? = nil
    ) async {
        let lifecycleConversationID = conversationID
        let lifecycle = if let lifecycleConversationID {
            await currentLifecycleSnapshot(for: lifecycleConversationID)
        } else {
            await currentLifecycleSnapshot()
        }
        let isCurrentGeneration = token == lifecycle.streamingGenerationSequence
        var shouldClearStreamingLifecycleFromRunMatch = false
        if let terminalStatus, let cid = conversationID, let rid = runID {
            do {
                switch terminalStatus {
                case .completed:
                    if terminalReason?.category == .boundedStop {
                        try await routingPersistRunLifecycleTranscriptMarker(
                            conversationID: cid,
                            payload: RunLifecycleTranscriptMarkerPayload(
                                kind: .run_bounded,
                                runId: rid,
                                terminalReason: terminalReason
                            )
                        )
                    }
                case .cancelled:
                    try await routingPersistRunLifecycleTranscriptMarker(
                        conversationID: cid,
                        payload: RunLifecycleTranscriptMarkerPayload(
                            kind: .run_cancelled,
                            runId: rid,
                            reason: markerKind ?? "user-cancel",
                            terminalReason: terminalReason
                        )
                    )
                case .failed:
                    try await routingPersistRunLifecycleTranscriptMarker(
                        conversationID: cid,
                        payload: RunLifecycleTranscriptMarkerPayload(
                            kind: .run_errored,
                            runId: rid,
                            terminalReason: terminalReason
                        )
                    )
                case .running:
                    break
                }
            } catch {
                deps.logger?.warning("[AgentRuntimeSessionService] run lifecycle transcript marker failed: \(error)")
            }

            if let conversation = await modelConversation(id: cid) {
                let runtimeRunMatchesConversationTerminal =
                    lifecycle.currentStreamingRunID == rid &&
                    (lifecycle.activeStreamingConversationID == cid || lifecycle.activeStreamingConversationID == nil)
                shouldClearStreamingLifecycleFromRunMatch = runtimeRunMatchesConversationTerminal

                let shouldApplyTerminalReset: Bool
                if conversation.currentRunID == rid {
                    shouldApplyTerminalReset = true
                } else if conversation.currentRunID == nil,
                          isCurrentGeneration,
                          lifecycle.currentStreamingRunID == rid {
                    shouldApplyTerminalReset = true
                } else {
                    shouldApplyTerminalReset = runtimeRunMatchesConversationTerminal
                }

                if shouldApplyTerminalReset, var latestConversation = await modelConversation(id: cid) {
                    latestConversation.state = .idle
                    latestConversation.agenticPhase = .idle
                    latestConversation.llmRequestPhase = nil
                    latestConversation.currentRunID = nil
                    await updateConversation(latestConversation)
                    await refreshProjectedConversationMessages(
                        conversationID: cid,
                        baseMessagesOverride: nil
                    )
                    await touchCurrentMessagesIfSelected(conversationID: cid, conversation: latestConversation)
                } else {
                    deps.logger?.debug(
                        "[AgentRuntimeSessionService] skipped terminal reset due to run mismatch conversationID=\(cid.uuidString) terminalRunID=\(rid.uuidString) conversationRunID=\(conversation.currentRunID?.uuidString ?? "nil") currentStreamingRunID=\(lifecycle.currentStreamingRunID?.uuidString ?? "nil") generationToken=\(token) activeGeneration=\(lifecycle.streamingGenerationSequence)"
                    )
                }
            }
            await releaseRunLane(runID: rid)
        }
        guard isCurrentGeneration || shouldClearStreamingLifecycleFromRunMatch else { return }
        if !isCurrentGeneration, shouldClearStreamingLifecycleFromRunMatch {
            deps.logger?.warning(
                "[AgentRuntimeSessionService] recovered terminal cleanup from generation mismatch conversationID=\(conversationID?.uuidString ?? "nil") runID=\(runID?.uuidString ?? "nil") generationToken=\(token) activeGeneration=\(lifecycle.streamingGenerationSequence)"
            )
        }
        if let lifecycleConversationID {
            await updateLifecycle(for: lifecycleConversationID) { lifecycle in
                lifecycle.generationTask = nil
                lifecycle.currentStreamingRunID = nil
                lifecycle.activeStreamingConversationID = nil
                lifecycle.activeAnchorUserMessageID = nil
                lifecycle.isContentStreamingActive = false
            }
        } else {
            await updateLifecycle { lifecycle in
                lifecycle.generationTask = nil
                lifecycle.currentStreamingRunID = nil
                lifecycle.activeStreamingConversationID = nil
                lifecycle.activeAnchorUserMessageID = nil
                lifecycle.isContentStreamingActive = false
            }
        }
        if let cid = conversationID, let rid = runID {
            await flushPendingModeTransitionAfterRunTerminal(
                conversationID: cid,
                runID: rid,
                terminalCategory: terminalReason?.category
            )
        }
    }

    func yieldOrchestrationSnapshot(_ snapshot: ConversationOrchestrationState) {
        sessionState.turnStateContinuation?.yield(snapshot)
    }

    func orchestrationEmissionConversationID() async -> UUID? {
        await orchestrationCore.orchestrationEmissionConversationID()
    }

    func lastOrchestrationEmissionConversationID() async -> UUID? {
        await orchestrationCore.orchestrationEmissionConversationID()
    }

    func setOrchestrationEmissionConversationID(_ conversationID: UUID?) async {
        await orchestrationCore.setOrchestrationEmissionConversationID(conversationID)
    }

    func lastTopicRefreshOrchestrationSnapshot() -> ConversationOrchestrationState? {
        sessionState.lastTopicRefreshOrchestrationSnapshot
    }

    func setLastTopicRefreshOrchestrationSnapshot(_ snapshot: ConversationOrchestrationState?) {
        sessionState.lastTopicRefreshOrchestrationSnapshot = snapshot
    }

    func lastPublishedSubAgentActivityPhase(conversationID: UUID) -> ConversationSubAgentActivityPhase {
        sessionState.lastPublishedSubAgentActivityPhaseByConversationID[conversationID] ?? .idle
    }

    func setLastPublishedSubAgentActivityPhase(
        _ phase: ConversationSubAgentActivityPhase,
        conversationID: UUID
    ) {
        if phase == .idle {
            sessionState.lastPublishedSubAgentActivityPhaseByConversationID.removeValue(forKey: conversationID)
        } else {
            sessionState.lastPublishedSubAgentActivityPhaseByConversationID[conversationID] = phase
        }
    }

    func orchestrationStateTopicRefreshHandler() -> (@Sendable (UUID, ConversationOrchestrationState) async -> Void)? {
        sessionState.orchestrationStateTopicRefreshHandler
    }

    func applyLLMContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) async {
        await orchestrationCore.applyLLMContextSnapshot(
            for: conversationID,
            from: response,
            requestConfig: requestConfig
        )
    }

    func pendingTerminalReasonForSnapshot(conversationID: UUID, runID: UUID?) -> ConversationRunTerminalReason? {
        if let runID {
            return sessionState.pendingTerminalReasons[RunSnapshotKey(conversationID: conversationID, runID: runID)]
        }
        // runID cleared before snapshot build (markStreamingGenerationCompleteIfCurrent ran first):
        // fall back to any pending reason for this conversation.
        return sessionState.pendingTerminalReasons.first(where: { $0.key.conversationID == conversationID })?.value
    }
}
