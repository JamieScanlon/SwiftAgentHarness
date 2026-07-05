import Combine
import CryptoKit
import EasyJSON
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitA2A
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Test hooks

extension HarnessRuntimeSession {
/// Mirrors orchestrator-delivered message handling (`updateCurrentConversation`).
    internal func testing_applyOrchestratorMessages(_ messages: [Message]) async {
        await updateCurrentConversation(withMessages: messages)
    }

    /// Persists a split through the user anchor (inclusive) and selects the new thread, without starting LLM streaming.
    internal func testing_persistSplitConversationAtUserMessage(sourceConversationID: UUID, messageID: UUID) async throws -> UUID {
        let (newConversationID, _) = try await persistSplitConversationSelectingNewThread(
            sourceConversationID: sourceConversationID,
            atUserMessageID: messageID
        )
        return newConversationID
    }

    /// Test-only: adjust registry `updatedAt` (e.g. soft-delete retention purge tests).
    internal func testing_setRegistryConversationUpdatedAt(conversationID: UUID, updatedAt: Date) async {
        guard var c = await persistenceDomain.modelConversation(id: conversationID) else { return }
        c.updatedAt = updatedAt
        await persistenceDomain.replaceConversationInRegistry(c)
    }

    internal func testing_setOrchestratorConversationID(_ id: UUID?) async {
        await agentRuntimeSessionService.testing_setOrchestratorConversationID(id)
    }

    internal func testing_modelConversation(conversationID: UUID) async -> ModelConversation? {
        await persistenceDomain.modelConversation(id: conversationID)
    }

    /// Test-only: run ``refreshProjectedConversationMessages`` (same path as after event writes).
    internal func testing_refreshProjectedConversationMessages(conversationID: UUID) async {
        await conversationMessagingRuntimeService.refreshProjectedConversationMessages(conversationID: conversationID)
    }

    /// Test-only: wait until the active streaming generation task for this conversation/run has finished.
    internal func testing_awaitStreamingGenerationSettled(
        conversationID: UUID,
        runID: UUID?,
        timeoutMS: Int = 10_000
    ) async {
        await waitUntilStreamingGenerationSettles(
            conversationID: conversationID,
            runID: runID,
            timeoutMS: timeoutMS
        )
    }

    func waitUntilStreamingGenerationSettles(
        conversationID: UUID,
        runID: UUID?,
        timeoutMS: Int = 60_000
    ) async {
        await conversationMessagingRuntimeService.waitUntilStreamingGenerationSettled(
            conversationID: conversationID,
            runID: runID,
            timeoutMS: timeoutMS
        )
    }

    /// Test-only: install a synthetic `lastPromptTokens` value that mirrors what
    /// `recordContextSnapshot` would store after a successful LLM response. Used by isolation
    /// tests that need to drive the proactive trigger without a real orchestrator round-trip.
    internal func testing_setLastPromptTokens(_ value: Int?) async {
        await agentRuntimeSessionService.testing_setLastPromptTokens(value)
    }

    internal func testing_currentLastPromptTokens() async -> Int? {
        await agentRuntimeSessionService.testing_currentLastPromptTokens()
    }

    internal func testing_setLastContextLimitTokens(_ value: Int?) async {
        await agentRuntimeSessionService.testing_setLastContextLimitTokens(value)
    }

    internal func testing_currentLastContextLimitTokens() async -> Int? {
        await agentRuntimeSessionService.testing_currentLastContextLimitTokens()
    }

    internal func testing_resetContextTokenSnapshot() async {
        await agentRuntimeSessionService.testing_resetContextTokenSnapshot()
    }

    /// Test-only: force conversation harness state for slash-command queue / busy gating tests.
    internal func testing_setSlashDispatchConversationState(
        conversationID: UUID,
        state: ModelState,
        agenticPhase: ConversationAgenticPhase
    ) async {
        guard var c = await persistenceDomain.modelConversation(id: conversationID) else { return }
        c.state = state
        c.agenticPhase = agenticPhase
        await persistenceDomain.replaceConversationInRegistry(c)
    }

    /// Test-only: force full runtime state fields used by terminal-reset regression coverage.
    internal func testing_setConversationRuntimeState(
        conversationID: UUID,
        state: ModelState,
        agenticPhase: ConversationAgenticPhase,
        llmRequestPhase: ConversationLLMRequestPhase?,
        currentRunID: UUID?
    ) async {
        guard var c = await persistenceDomain.modelConversation(id: conversationID) else { return }
        c.state = state
        c.agenticPhase = agenticPhase
        c.llmRequestPhase = llmRequestPhase
        c.currentRunID = currentRunID
        await persistenceDomain.replaceConversationInRegistry(c)
    }

    internal func testing_mergeRuntimeState(
        conversationID: UUID,
        snapshot: ModelConversation
    ) async -> ModelConversation {
        var merged = snapshot
        await preserveLatestRuntimeState(conversationID: conversationID, conversation: &merged)
        return merged
    }

    internal func testing_installTurnStateContinuation() async {
        await agentRuntimeSessionService.testing_installTurnStateContinuation()
    }

    internal func testing_clearTurnStateContinuation() async {
        await agentRuntimeSessionService.testing_clearTurnStateContinuation()
    }

    internal func testing_setActiveStreamingRun(conversationID: UUID?, runID: UUID?) async {
        await agentRuntimeSessionService.testing_setActiveStreamingRun(
            conversationID: conversationID,
            runID: runID
        )
    }

    internal func testing_ensureOrchestratorPoolEntry(model: Model, conversation: ModelConversation) async {
        guard let acquisition = await orchestratorRuntimeService.acquireOrchestrator(
            conversation: conversation,
            model: model
        ) else {
            return
        }
        await orchestratorRuntimeService.releaseOrchestrator(acquisition.handle)
    }

    internal func testing_setCurrentStreamingRunID(_ runID: UUID?) async {
        await agentRuntimeSessionService.testing_setCurrentStreamingRunID(runID)
    }

    internal func testing_setContentStreamingActive(_ isActive: Bool) async {
        await agentRuntimeSessionService.testing_setContentStreamingActive(isActive)
    }

    internal func testing_setGenerationTaskActive(_ isActive: Bool) async {
        await agentRuntimeSessionService.testing_setGenerationTaskActive(isActive)
    }

    internal func testing_setPreRunStateSendHook(
        _ hook: (@Sendable (ModelConversation) async -> Void)?
    ) async {
        await services.conversationSelectionRuntimeService.testing_setPreRunStateSendHook(hook)
    }

    internal func testing_setCurrentConversationID(_ id: UUID?) async {
        await services.conversationSelectionRuntimeService.testing_setCurrentConversationID(id)
    }

    internal func testing_seedProjectionPublishState(conversationID: UUID, frontierEventID: Int, contentHash: Int) async {
        await services.sessionProjectionRuntimeService.testing_seedProjectionPublishState(
            conversationID: conversationID,
            frontierEventID: frontierEventID,
            contentHash: contentHash
        )
    }

    internal func testing_clearProjectionPublishState(conversationID: UUID) async {
        await services.sessionProjectionRuntimeService.testing_clearProjectionPublishState(conversationID: conversationID)
    }

    internal func testing_setupOrchestratorWithoutConversation(model: Model) async {
        await orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: nil)
    }

    internal func testing_rebindOrchestrator(for conversation: ModelConversation) async {
        await orchestratorSessionRuntimeService.setupOrchestrator(
            with: conversation.model,
            activeConversation: conversation
        )
    }

    internal func testing_teardownActiveStreaming() async {
        await agentRuntimeSessionService.cancelGeneration()
        await agentRuntimeSessionService.cancelInFlightStreamingGenerationOnly()
    }

    internal struct TestingDispatchPrimaryModelResolution: Sendable, Equatable {
        let modelID: UUID
        let usedModeFallback: Bool
    }

    internal func testing_resolveDispatchPrimaryModelForCurrentConversation() async -> TestingDispatchPrimaryModelResolution? {
        guard let conversation = await currentConversation() else { return nil }
        let selectedModel = conversation.model
        let primaryEntry = await runtimeDependencies.registryEntryProvider?(selectedModel.id)
        guard let resolved = await orchestratorRuntimeService.resolveDispatchPrimaryModel(
            selectedModel: selectedModel,
            primaryEntry: primaryEntry,
            activeConversation: conversation
        ) else {
            return nil
        }
        return TestingDispatchPrimaryModelResolution(
            modelID: resolved.model.id,
            usedModeFallback: resolved.usedModeFallback
        )
    }

    internal func traceSnapshotForConversationAPI(conversationID: UUID) async -> TraceTopicPayload {
        await runtimeLifecyclePublicationService.traceSnapshotForConversation(conversationID: conversationID)
    }

    internal func traceSnapshotForServerAPI() async -> TraceTopicPayload {
        await runtimeLifecyclePublicationService.traceSnapshotForServer()
    }

    internal func listConversationTracesForAPI(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        guard await persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        return await runtimeLifecyclePublicationService.listConversationTraces(
            conversationID: conversationID,
            limit: limit
        )
    }

    func cancelSubAgentChildRun(childConversationID: UUID) async {
        guard let runID = await persistenceDomain.modelConversation(id: childConversationID)?.currentRunID else {
            return
        }
        try? await cancelActiveRunForAPI(conversationID: childConversationID, runID: runID)
    }

    internal func testing_pendingSlashCommandCount(conversationID: UUID) async -> Int {
        await slashCommandDispatchService.pendingSlashCommandCount(conversationID: conversationID)
    }

    internal func testing_runSlashCommandIfNeeded(
        _ text: String,
        conversationID: UUID,
        skipQueue: Bool = true,
        isOwner: Bool? = nil
    ) async throws -> ChatStreamResponse? {
        let resolvedIsOwner: Bool
        if let isOwner {
            resolvedIsOwner = isOwner
        } else {
            resolvedIsOwner = await slashCommandDispatchService.resolvedSlashDispatchIsOwner(conversationID: conversationID)
        }
        return try await slashCommandDispatchService.runSlashCommandIfNeeded(
            text,
            conversationID: conversationID,
            skipQueue: skipQueue,
            isOwner: resolvedIsOwner
        )
    }

    internal func testing_runSlashCommandIfNeededViaDispatchingProtocol(
        _ text: String,
        conversationID: UUID
    ) async throws -> ChatStreamResponse? {
        let slashCommand: any SlashCommandRuntimeDispatching = slashCommandDispatchService
        return try await slashCommand.runSlashCommandIfNeeded(text, conversationID: conversationID)
    }
}
