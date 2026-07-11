import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

/// Early-wirable orchestrator binding, lifecycle, token, and residual orchestration state.
actor AgentRuntimeOrchestrationCore {
    private let pool: OrchestratorPool
    private var lastOrchestrationEmissionConversationID: UUID?

    init(maxPoolEntries: Int = Int.max, idleTTLSeconds: TimeInterval = 300) {
        pool = OrchestratorPool(maxEntries: maxPoolEntries, idleTTLSeconds: idleTTLSeconds)
    }

    var orchestratorPool: OrchestratorPool { pool }

    func setOrchestratorTeardownHandler(_ handler: @escaping OrchestratorPoolTeardown) async {
        await pool.setTeardownHandler(handler)
    }

    func clearBinding() async {
        await pool.clearBinding()
    }

    func currentLifecycleSnapshot(for conversationID: UUID? = nil) async -> ChatRuntimeLifecycle {
        if let conversationID,
           let lifecycle = await pool.lifecycleSnapshot(for: conversationID) {
            return lifecycle
        }
        return await pool.activeStreamingLifecycleSnapshot()
    }

    func mutateLifecycle(
        for conversationID: UUID? = nil,
        _ mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void
    ) async {
        if let conversationID {
            await pool.mutateLifecycle(for: conversationID, mutate: mutate)
        } else {
            await pool.mutateActiveStreamingLifecycle(mutate: mutate)
        }
    }

    func tokenSnapshotsForOrchestration(conversationID: UUID? = nil) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?
    ) {
        let snapshot = await tokenMetrics(conversationID: conversationID)
        return (snapshot.lastPromptTokens, snapshot.lastContextLimitTokens)
    }

    func contextTokenMetricsForOrchestration(conversationID: UUID? = nil) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?,
        lastRemainingContextTokens: Int?
    ) {
        let snapshot = await tokenMetrics(conversationID: conversationID)
        return (
            snapshot.lastPromptTokens,
            snapshot.lastContextLimitTokens,
            snapshot.lastRemainingContextTokens
        )
    }

    private func tokenMetrics(conversationID: UUID?) async -> OrchestratorPoolEntryTokenSnapshot {
        if let conversationID,
           let snapshot = await pool.tokenSnapshot(for: conversationID) {
            return snapshot
        }
        return OrchestratorPoolEntryTokenSnapshot()
    }

    func resetTokenSnapshot(for conversationID: UUID? = nil) async {
        if let conversationID {
            await pool.resetTokenSnapshot(for: conversationID)
        } else {
            await pool.resetAllTokenSnapshots()
        }
    }

    func applyLLMContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) async {
        await pool.applyLLMContextSnapshot(
            for: conversationID,
            from: response,
            requestConfig: requestConfig
        )
    }

    func orchestrationEmissionConversationID() -> UUID? {
        lastOrchestrationEmissionConversationID
    }

    func setOrchestrationEmissionConversationID(_ conversationID: UUID?) {
        lastOrchestrationEmissionConversationID = conversationID
    }

    func acquireOrchestrator(
        conversationID: UUID,
        modelName: String,
        buildIfMissing: @escaping OrchestratorPoolBuildFactory
    ) async -> OrchestratorAcquisition? {
        await pool.acquire(
            conversationID: conversationID,
            modelName: modelName,
            buildIfMissing: buildIfMissing
        )
    }

    func releaseOrchestrator(_ handle: OrchestratorHandle) async {
        await pool.release(handle)
    }

    func invalidateOrchestrator(for conversationID: UUID) async {
        await pool.invalidate(conversationID: conversationID)
    }

    func evictIdleOrchestrators() async {
        await pool.evictIdle()
    }

    func testing_setOrchestratorConversationID(_ id: UUID?) async {
        await pool.testing_setOrchestratorConversationID(id)
    }

    func testing_setLastPromptTokens(_ value: Int?, conversationID: UUID) async {
        await pool.testing_setLastPromptTokens(value, for: conversationID)
    }

    func testing_currentLastPromptTokens(conversationID: UUID) async -> Int? {
        await pool.testing_currentLastPromptTokens(for: conversationID)
    }

    func testing_setLastContextLimitTokens(_ value: Int?, conversationID: UUID) async {
        await pool.testing_setLastContextLimitTokens(value, for: conversationID)
    }

    func testing_currentLastContextLimitTokens(conversationID: UUID) async -> Int? {
        await pool.testing_currentLastContextLimitTokens(for: conversationID)
    }

    func testing_poolEntryCount() async -> Int {
        await pool.entryCount()
    }

    func testing_poolRefCount(for conversationID: UUID) async -> Int {
        await pool.testing_poolRefCount(for: conversationID)
    }
}

extension AgentRuntimeOrchestrationCore: AgentRuntimeOrchestratorBinding {
    func orchestrator(for conversationID: UUID) async -> SwiftAgentKitOrchestrator? {
        await pool.orchestrator(for: conversationID)
    }

    func lifecycleSnapshot(for conversationID: UUID?) async -> ChatRuntimeLifecycle {
        await currentLifecycleSnapshot(for: conversationID)
    }

    func clearOrchestratorBinding() async { await clearBinding() }

    func resetContextTokenSnapshot() async { await resetTokenSnapshot(for: nil) }

    func recordContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) async {
        await applyLLMContextSnapshot(for: conversationID, from: response, requestConfig: requestConfig)
    }

    func updateLifecycle(
        for conversationID: UUID,
        mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void
    ) async {
        await mutateLifecycle(for: conversationID, mutate)
    }

    func updateLifecycle(_ mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void) async {
        await mutateLifecycle(for: nil, mutate)
    }
}

extension AgentRuntimeOrchestrationCore: AgentRuntimeTokenSnapshotting {
    @available(*, deprecated, message: "Use tokenSnapshotsForOrchestration(for:) with an explicit conversationID.")
    func tokenSnapshotsForOrchestration() async -> (lastPromptTokens: Int?, lastContextLimitTokens: Int?) {
        await tokenSnapshotsForOrchestration(conversationID: nil)
    }

    func tokenSnapshotsForOrchestration(for conversationID: UUID) async -> (
        lastPromptTokens: Int?,
        lastContextLimitTokens: Int?
    ) {
        await tokenSnapshotsForOrchestration(conversationID: conversationID)
    }

    func lastModelRequestAt(for conversationID: UUID) async -> Date? {
        await pool.lastModelRequestAt(for: conversationID)
    }
}

extension AgentRuntimeOrchestrationCore: AgentRuntimeResidualStateReading {
    func lastOrchestrationEmissionConversationID() async -> UUID? {
        orchestrationEmissionConversationID()
    }
}
