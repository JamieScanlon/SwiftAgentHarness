import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    var isOrchestratorPortInstalled: Bool {
        (orchestratorPort as? OrchestratorSessionPortAdapter)?.isInstalled ?? false
    }

    var isSessionBound: Bool { isOrchestratorPortInstalled }

    func currentLifecycleSnapshot(for conversationID: UUID? = nil) async -> ChatRuntimeLifecycle {
        await orchestrationCore.currentLifecycleSnapshot(for: conversationID)
    }

    func updateLifecycle(
        for conversationID: UUID,
        _ mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void
    ) async {
        await orchestrationCore.mutateLifecycle(for: conversationID, mutate)
    }

    func updateLifecycle(_ mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void) async {
        await orchestrationCore.mutateLifecycle(for: nil, mutate)
    }

    func modelConversation(id: UUID) async -> ModelConversation? {
        await deps.persistenceDomain.modelConversation(id: id)
    }

    func modelConversationWhenSessionLive(id: UUID) async -> ModelConversation? {
        guard isOrchestratorPortInstalled else { return nil }
        return await modelConversation(id: id)
    }

    func sessionLaneKey(conversationID: UUID) async -> String {
        await selection.runtimeSessionLaneKey(conversationID: conversationID)
    }

    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID
    ) async -> ConversationServiceError {
        await selection.runtimeSessionError(
            for: admissionError,
            conversationID: conversationID,
            fallbackRunID: fallbackRunID,
            activeRuntimeRunIDOverride: nil
        )
    }

    func shouldMirrorSelectionToGlobalChatState() async -> Bool {
        await selection.shouldMirrorSelectionToGlobalChatState()
    }

    func setTurnStateContinuation(_ continuation: AsyncStream<ConversationOrchestrationState>.Continuation?) {
        sessionState.turnStateContinuation = continuation
    }

    func finishOrchestrationStateStream() {
        sessionState.turnStateContinuation?.finish()
        sessionState.turnStateContinuation = nil
    }

    func setPendingTerminalReason(
        _ reason: ConversationRunTerminalReason?,
        conversationID: UUID,
        runID: UUID
    ) {
        let key = RunSnapshotKey(conversationID: conversationID, runID: runID)
        if let reason {
            sessionState.pendingTerminalReasons[key] = reason
        } else {
            sessionState.pendingTerminalReasons.removeValue(forKey: key)
        }
    }

    var toolApproval: any ToolApprovalRuntimeServicing { outbound.toolApproval }
    var orchestratorRuntime: any OrchestratorRuntimeToolPolicyServicing { outbound.orchestratorRuntime }
    var contextProjection: any ContextProjectionTransformServicing { outbound.contextProjection }
    var slashCommand: any SlashCommandRuntimeDispatching { outbound.slashCommand }

    func testing_setOrchestratorConversationID(_ id: UUID?) async {
        await orchestrationCore.testing_setOrchestratorConversationID(id)
    }

    func testing_currentClearBindingCallCount() async -> Int {
        testing_clearBindingCallCount
    }

    func testing_setLastPromptTokens(_ value: Int?) async {
        let conversationID = await selection.currentConversationID()
        guard let conversationID else { return }
        await orchestrationCore.testing_setLastPromptTokens(value, conversationID: conversationID)
    }

    func testing_currentLastPromptTokens() async -> Int? {
        guard let conversationID = await selection.currentConversationID() else { return nil }
        return await orchestrationCore.testing_currentLastPromptTokens(conversationID: conversationID)
    }

    func testing_setLastContextLimitTokens(_ value: Int?) async {
        let conversationID = await selection.currentConversationID()
        guard let conversationID else { return }
        await orchestrationCore.testing_setLastContextLimitTokens(value, conversationID: conversationID)
    }

    func testing_currentLastContextLimitTokens() async -> Int? {
        guard let conversationID = await selection.currentConversationID() else { return nil }
        return await orchestrationCore.testing_currentLastContextLimitTokens(conversationID: conversationID)
    }

    func testing_installTurnStateContinuation() {
        let (_, continuation) = AsyncStream.makeStream(
            of: ConversationOrchestrationState.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        sessionState.turnStateContinuation = continuation
    }

    func testing_clearTurnStateContinuation() {
        sessionState.turnStateContinuation = nil
    }

    func testing_setActiveStreamingRun(conversationID: UUID?, runID: UUID?) async {
        if let conversationID {
            await updateLifecycle(for: conversationID) { lifecycle in
                lifecycle.generationTask?.cancel()
                lifecycle.activeStreamingConversationID = runID == nil ? nil : conversationID
                lifecycle.currentStreamingRunID = runID
                lifecycle.generationTask = runID == nil ? nil : Task {
                    try? await Task.sleep(nanoseconds: .max)
                }
            }
            return
        }
        await updateLifecycle { lifecycle in
            lifecycle.generationTask?.cancel()
            lifecycle.activeStreamingConversationID = conversationID
            lifecycle.currentStreamingRunID = runID
            lifecycle.generationTask = runID == nil ? nil : Task {
                try? await Task.sleep(nanoseconds: .max)
            }
        }
    }

    func testing_setCurrentStreamingRunID(_ runID: UUID?) async {
        await updateLifecycle { lifecycle in
            lifecycle.currentStreamingRunID = runID
        }
    }

    func testing_setContentStreamingActive(_ isActive: Bool) async {
        await updateLifecycle { $0.isContentStreamingActive = isActive }
    }

    func testing_setGenerationTaskActive(_ isActive: Bool) async {
        await updateLifecycle { lifecycle in
            lifecycle.generationTask?.cancel()
            lifecycle.generationTask = isActive ? Task {
                try? await Task.sleep(nanoseconds: .max)
            } : nil
        }
    }

    func cancelMessageStreamForAPI() async {
        await cancelMessageStream()
    }

    func setOrchestrationStateOutOfBandPush(
        id: UUID,
        push: @escaping @Sendable (ConversationOrchestrationState) async -> Void
    ) async {
        sessionState.orchestrationStateOutOfBandPush = (id, push)
    }

    func clearOrchestrationStateOutOfBandPush(id: UUID) async {
        if sessionState.orchestrationStateOutOfBandPush?.id == id {
            sessionState.orchestrationStateOutOfBandPush = nil
        }
    }

    func streamingGenerationSettled(conversationID: UUID, runID: UUID?) async -> Bool {
        let lifecycle = await currentLifecycleSnapshot(for: conversationID)
        guard lifecycle.generationTask != nil else { return true }
        guard lifecycle.activeStreamingConversationID == conversationID else { return true }
        guard let runID else { return false }
        guard let activeRunID = lifecycle.currentStreamingRunID else { return false }
        return activeRunID != runID
    }

    func testing_resetContextTokenSnapshot() async {
        await orchestrationCore.resetTokenSnapshot()
    }

    func testing_poolRefCount(for conversationID: UUID) async -> Int {
        await orchestrationCore.testing_poolRefCount(for: conversationID)
    }
}
