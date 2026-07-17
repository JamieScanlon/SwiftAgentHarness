import Foundation
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitA2A
import SwiftAgentKitACP

protocol StartupServicing: Sendable {
    func resetConversationsFromCatalog(availableModels: [Model]) async throws
    func refreshTranscriptIntegrityFlagsAfterMaintenance(report: SessionTranscriptIntegrityReport) async
    func budgetLedgerHydrationSeeds() async -> [BudgetLedgerHydrationSeed]
    func setConversationTopicPublisher(_ publisher: (any ConversationTopicPublishing)?) async
    func setTraceTopicPublisher(_ publisher: (any TraceTopicPublishing)?) async
    func setSubAgentLifecyclePublisher(_ publisher: (any SubAgentPoolResourceTopicPublishing)?) async
    func setResourceManager(_ resourceManager: ResourceManager) async
    func setMCPManager(
        _ mcpManager: MCPManager,
        visibilityGrant: ToolVisibilityGrant
    ) async
    func setA2AManager(_ a2aManager: A2AManager) async
    func conversationWireCurrentRunID(conversationID: UUID) async -> UUID
    func purgeSoftDeletedPastRetention(retentionDays: Int, now: Date) async throws -> Int
    func runDerivedArtifactRetentionSweep(policy: DerivedArtifactRetentionPolicy) async throws -> DerivedArtifactRetentionSweepResult
}

extension StartupServicing {
    func setMCPManager(_ mcpManager: MCPManager) async {
        await setMCPManager(mcpManager, visibilityGrant: .inheritModeLists)
    }
}

/// Server startup, retention sweeps, and composition-root publisher wiring (Slice 6 migration).
public actor ConversationStartupService: StartupServicing {
    private let deps: ConversationRuntimeDependencies
    private let orchestrationCore: AgentRuntimeOrchestrationCore
    private let sessionProjection: SessionProjectionAccessing
    private let messaging: ConversationMessagingPort
    nonisolated(unsafe) private var spawn: (any SubAgentSpawnLifecycleServicing)!
    private let runtimeLifecyclePublication: RuntimeLifecyclePublicationService
    private let lifecycle: any ConversationLifecycleServicing

    private var conversationTopicPublisher: (any ConversationTopicPublishing)?
    private var subAgentLifecyclePublisher: (any SubAgentPoolResourceTopicPublishing)?
    private var resourceManager: ResourceManager?
    private var mcpManager: MCPManager?
    private var a2aManager: A2AManager?
    private var acpManager: ACPManager?
    nonisolated(unsafe) private var subAgentA2AManagerProvider: SubAgentPoolA2AManagerProvider?
    nonisolated(unsafe) private var subAgentACPManagerProvider: SubAgentPoolACPManagerProvider?

    init(
        deps: ConversationRuntimeDependencies,
        orchestrationCore: AgentRuntimeOrchestrationCore,
        sessionProjection: SessionProjectionAccessing,
        messaging: ConversationMessagingPort,
        runtimeLifecyclePublication: RuntimeLifecyclePublicationService,
        lifecycle: any ConversationLifecycleServicing
    ) {
        self.deps = deps
        self.orchestrationCore = orchestrationCore
        self.sessionProjection = sessionProjection
        self.messaging = messaging
        self.runtimeLifecyclePublication = runtimeLifecyclePublication
        self.lifecycle = lifecycle
    }

    nonisolated func installSpawn(_ spawn: any SubAgentSpawnLifecycleServicing) {
        precondition(self.spawn == nil, "SubAgentSpawnService already installed")
        self.spawn = spawn
    }

    private var installedSpawn: any SubAgentSpawnLifecycleServicing {
        guard let spawn else {
            preconditionFailure("SubAgentSpawnService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return spawn
    }


    func conversationTopicPublisherForRuntime() -> (any ConversationTopicPublishing)? {
        conversationTopicPublisher
    }

    func subAgentLifecyclePublisherForRuntime() -> (any SubAgentPoolResourceTopicPublishing)? {
        subAgentLifecyclePublisher
    }

    func resourceManagerForRuntime() -> ResourceManager? {
        resourceManager
    }

    func mcpManagerForOrchestration() -> MCPManager? {
        mcpManager
    }

    func a2aManagerForOrchestration() -> A2AManager? {
        a2aManager
    }

    func acpManagerForOrchestration() -> ACPManager? {
        acpManager
    }

    public func resetConversationsFromCatalog(availableModels: [Model]) async throws {
        if SessionPersistenceConfiguration.transcriptVerifyOnStartup,
           let root = SessionPersistenceConfiguration.sessionStoreRoot {
            let report = try SessionTranscriptIntegrityScanner.runTranscriptIntegrityMaintenance(
                root: root,
                verifyAndRepair: true,
                logger: deps.logger
            )
            SessionTranscriptIntegrityMaintenance.logReport(report, phase: "boot", logger: deps.logger)
        }
        try await deps.persistenceDomain.resetConversationsFromCatalog(availableModels: availableModels)
        await durablyRepairOrphanedRunsAfterReset()
        await installedSpawn.rebuildSubAgentLifecycleFromPersistedConversations()
        var projectedByConversationID: [UUID: [Message]] = [:]
        for conversation in await deps.persistenceDomain.listConversationInfo() {
            projectedByConversationID[conversation.id] = await deps.persistenceDomain.projectedMessagesForUI(conversation: conversation)
        }
        await sessionProjection.replaceAllProjectedMessages(projectedByConversationID)
    }

    public func refreshTranscriptIntegrityFlagsAfterMaintenance(report: SessionTranscriptIntegrityReport) async {
        do {
            try await deps.persistenceDomain.refreshTranscriptIntegrityFromMaintenance(report: report)
            for sample in report.samples {
                guard let conversation = await deps.persistenceDomain.modelConversation(id: sample.conversationID) else { continue }
                await sessionProjection.syncFromRegistry(conversationID: sample.conversationID, conversation: conversation)
            }
        } catch {
            deps.logger?.warning("refreshTranscriptIntegrityFlagsAfterMaintenance failed: \(error)")
        }
    }

    public func budgetLedgerHydrationSeeds() async -> [BudgetLedgerHydrationSeed] {
        await deps.persistenceDomain.budgetLedgerHydrationSeeds()
    }

    public func setConversationTopicPublisher(_ publisher: (any ConversationTopicPublishing)?) async {
        conversationTopicPublisher = publisher
        await runtimeLifecyclePublication.setConversationTopicPublisher(publisher)
    }

    public func setTraceTopicPublisher(_ publisher: (any TraceTopicPublishing)?) async {
        await runtimeLifecyclePublication.setTraceTopicPublisher(publisher)
    }

    public func setSubAgentLifecyclePublisher(_ publisher: (any SubAgentPoolResourceTopicPublishing)?) async {
        subAgentLifecyclePublisher = publisher
    }

    public func setResourceManager(_ resourceManager: ResourceManager) async {
        self.resourceManager = resourceManager
    }

    public func setMCPManager(
        _ mcpManager: MCPManager,
        visibilityGrant: ToolVisibilityGrant = .inheritModeLists
    ) async {
        self.mcpManager = mcpManager
        deps.visibilityGrants.register(
            ToolVisibilityGrantRecord(
                id: ToolVisibilityGrantStore.mcpRegistrationID,
                grant: visibilityGrant,
                match: .registrySource(.mcp)
            )
        )
    }

    nonisolated func installSubAgentA2AManagerProvider(_ provider: SubAgentPoolA2AManagerProvider) {
        subAgentA2AManagerProvider = provider
    }

    nonisolated func installSubAgentACPManagerProvider(_ provider: SubAgentPoolACPManagerProvider) {
        subAgentACPManagerProvider = provider
    }

    public func setA2AManager(_ a2aManager: A2AManager) async {
        self.a2aManager = a2aManager
        await subAgentA2AManagerProvider?.setManager(a2aManager)
    }

    public func setACPManager(_ acpManager: ACPManager, delegateBoxes: [String: SubAgentACPClientDelegateBox]) async {
        self.acpManager = acpManager
        await subAgentACPManagerProvider?.setBootstrap(manager: acpManager, delegateBoxes: delegateBoxes)
    }

    func installSubAgentACPClientDelegateFactory(_ factory: any SubAgentACPClientDelegateMaking) async {
        await subAgentACPManagerProvider?.setDelegateFactory(factory)
    }

    public func conversationWireCurrentRunID(conversationID: UUID) async -> UUID {
        let lifecycleSnapshot = await orchestrationCore.lifecycleSnapshot(for: conversationID)
        return await deps.persistenceDomain.modelConversation(id: conversationID)?.currentRunID
            ?? lifecycleSnapshot.currentStreamingRunID
            ?? UUID()
    }

    public func purgeSoftDeletedPastRetention(retentionDays: Int, now: Date = Date()) async throws -> Int {
        guard retentionDays > 0 else { return 0 }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return 0 }
        let staleIDs = await deps.persistenceDomain.conversations
            .filter { $0.lifecycle == .deleted && $0.updatedAt < cutoff }
            .map(\.id)
        var purged = 0
        for id in staleIDs {
            try await lifecycle.deleteConversation(conversationID: id, hard: true)
            purged += 1
        }
        return purged
    }

    public func runDerivedArtifactRetentionSweep(
        policy: DerivedArtifactRetentionPolicy
    ) async throws -> DerivedArtifactRetentionSweepResult {
        try await deps.persistenceDomain.runDerivedArtifactRetentionSweep(policy: policy)
    }

    public func shutdown(
        agentRuntime: AgentRuntimeSessionService,
        conversationReplay: ConversationReplayService,
        orchestratorRuntime: OrchestratorRuntimeService
    ) async {
        await shutdownOrchestratorAndToolRuntimes(
            agentRuntime: agentRuntime,
            conversationReplay: conversationReplay,
            orchestratorRuntime: orchestratorRuntime
        )
    }

    public func shutdownOrchestratorAndToolRuntimes(
        agentRuntime: AgentRuntimeSessionService,
        conversationReplay: ConversationReplayService,
        orchestratorRuntime: OrchestratorRuntimeService
    ) async {
        await installedSpawn.stopCompletionHandoffOwner()
        await conversationReplay.cancelAllActiveTasks()
        let pendingGeneration = await agentRuntime.lifecycleSnapshot(for: nil).generationTask
        await agentRuntime.cancelGeneration()

        await orchestratorRuntime.shutdownToolRuntimes(existingOrchestrator: nil)
        await agentRuntime.clearOrchestratorBinding()
        if let pendingGeneration {
            _ = await pendingGeneration.result
        }
    }

    private func durablyRepairOrphanedRunsAfterReset() async {
        let infos = await deps.persistenceDomain.listConversationInfo()
        for info in infos {
            let lifecycle = await orchestrationCore.currentLifecycleSnapshot(for: info.id)
            let orphanRunIDs = await deps.persistenceDomain.runIDsRequiringDurableOrphanRepair(
                conversationID: info.id,
                activeRuntimeRunID: lifecycle.currentStreamingRunID,
                activeRuntimeConversationID: lifecycle.activeStreamingConversationID
            )
            guard !orphanRunIDs.isEmpty else { continue }

            for runID in orphanRunIDs {
                do {
                    try await deps.persistenceDomain.routingPersistRunLifecycleTranscriptMarker(
                        conversationID: info.id,
                        payload: RunLifecycleTranscriptMarkerPayload(
                            kind: .run_orphaned,
                            runId: runID,
                            reason: "stale_running_reconciled",
                            terminalReason: ConversationRunTerminalReason(
                                category: .failure,
                                detail: "stale_running_reconciled"
                            )
                        )
                    )
                } catch {
                    deps.logger?.warning("[ConversationStartupService] orphan run transcript marker failed (conversation=\(info.id), run=\(runID)): \(error)")
                }
            }

            if var conversation = await deps.persistenceDomain.modelConversation(id: info.id),
               let currentRunID = conversation.currentRunID,
               orphanRunIDs.contains(currentRunID) {
                conversation.currentRunID = nil
                conversation.state = .idle
                conversation.agenticPhase = .idle
                conversation.llmRequestPhase = nil
                await messaging.update(conversation: conversation)
            }
        }
    }
}
