import Foundation
import SwiftAgentKit

actor ConversationLifecycleServiceImpl: ConversationLifecycleServicing {
    private let deps: ConversationRuntimeDependencies
    nonisolated(unsafe) private var runControl: (any AgentRuntimeRunControlling)!
    private let orchestratorRuntime: OrchestratorRuntimeService
    private let conversationReplay: ConversationReplayService
    private let selection: ConversationSelectionAccessing
    private let orchestrator: OrchestratorSessionPort
    private let topics: ConversationTopicPublicationPort
    private let sessionProjection: SessionProjectionAccessing

    init(
        deps: ConversationRuntimeDependencies,
        orchestratorRuntime: OrchestratorRuntimeService,
        conversationReplay: ConversationReplayService,
        selection: ConversationSelectionAccessing,
        orchestrator: OrchestratorSessionPort,
        topics: ConversationTopicPublicationPort,
        sessionProjection: SessionProjectionAccessing
    ) {
        self.deps = deps
        self.orchestratorRuntime = orchestratorRuntime
        self.conversationReplay = conversationReplay
        self.selection = selection
        self.orchestrator = orchestrator
        self.topics = topics
        self.sessionProjection = sessionProjection
    }

    nonisolated func installRunControl(_ runControl: any AgentRuntimeRunControlling) {
        precondition(self.runControl == nil, "AgentRuntimeRunControlling already installed")
        self.runControl = runControl
    }

    private var installedRunControl: any AgentRuntimeRunControlling {
        guard let runControl else {
            preconditionFailure("AgentRuntimeRunControlling not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return runControl
    }

    func deleteConversation(conversationID: UUID, hard: Bool) async throws {
        await conversationReplay.stopConversationReplay(conversationID: conversationID)
        if !hard {
            try? await selection.reselectAfterDelete(deletedConversationID: conversationID)
            try await deps.persistenceDomain.softDeleteConversation(conversationID: conversationID)
            return
        }
        try? await selection.reselectAfterDelete(deletedConversationID: conversationID)
        try await deps.persistenceDomain.deleteConversation(conversationID: conversationID)
    }

    func branchConversation(
        conversationID: UUID,
        userMessageID: UUID,
        selectionBehavior: BranchSelectionBehavior,
        childLineageKind: ConversationLineageKind = .branch
    ) async throws -> UUID {
        let priorSelection = selectionBehavior == .preserveForeground
            ? await selection.currentConversationID()
            : nil
        await installedRunControl.cancelGeneration(for: conversationID)
        await orchestratorRuntime.invalidateOrchestrator()
        if selectionBehavior == .adoptChild {
            try await selection.selectConversation(conversationID: conversationID)
        }
        let (newID, _) = try await persistSplitSelectingNewThread(
            sourceConversationID: conversationID,
            atUserMessageID: userMessageID,
            adoptSelection: selectionBehavior == .adoptChild,
            childLineageKind: childLineageKind
        )
        if selectionBehavior == .preserveForeground,
           let priorSelection,
           priorSelection != newID {
            try await selection.selectConversation(conversationID: priorSelection)
        }
        return newID
    }

    func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        let newConversation = try await deps.persistenceDomain.copyConversation(
            from: sourceConversationID,
            to: model,
            systemPrompt: systemPrompt
        )
        let journalMessages = try await deps.persistenceDomain.messagesNeedingTranscriptMessageAppendedJournal(
            conversationID: newConversation.id,
            messages: newConversation.messages
        )
        if !journalMessages.isEmpty {
            try await deps.persistenceDomain.routingAppendMessageJournalEntriesAsync(
                conversationID: newConversation.id,
                messages: journalMessages
            )
        }
        try? await orchestrator.adoptPersistedNewConversationSelection(newConversation)
        return newConversation.id
    }

    func invalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        let resolved = kinds.isEmpty ? ConversationDerivedCheckpointKinds.allInvalidationKinds : kinds
        try await deps.persistenceDomain.routingAppendCheckpointInvalidationAsync(
            conversationID: conversationID,
            kinds: resolved
        )
        await topics.publishCheckpointInvalidationOnTopic(
            conversationID: conversationID,
            invalidatedKinds: resolved
        )
    }

    func latestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        await deps.persistenceDomain.latestCheckpointResponse(
            conversationID: conversationID,
            compactionConfig: deps.conversationTransformConfiguration.contextCompaction,
            harnessCheckpointKind: kind
        )
    }

    func listEngineArtifactKeys(conversationID: UUID) async throws -> [String] {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        do {
            return try await deps.persistenceDomain.listEngineArtifactKeys(conversationID: conversationID)
        } catch let error as SessionPersistenceError {
            if case .unsupportedOperation = error {
                throw APILayerConversationAPIError.unsupported
            }
            throw error
        }
    }

    func getEngineArtifact(conversationID: UUID, key: String) async throws -> Data? {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        return try await deps.persistenceDomain.getEngineArtifact(conversationID: conversationID, key: key)
    }

    func putEngineArtifact(conversationID: UUID, key: String, data: Data) async throws {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        do {
            try await deps.persistenceDomain.putEngineArtifact(
                conversationID: conversationID,
                key: key,
                data: data
            )
        } catch let error as SessionPersistenceError {
            if case .unsupportedOperation = error {
                throw APILayerConversationAPIError.unsupported
            }
            throw error
        }
    }

    func evictEngineArtifacts(conversationID: UUID, key: String?) async throws {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        try await deps.persistenceDomain.evictEngineArtifacts(conversationID: conversationID, key: key)
    }

    func persistSplitSelectingNewThread(
        sourceConversationID: UUID,
        atUserMessageID messageID: UUID,
        adoptSelection: Bool,
        childLineageKind: ConversationLineageKind = .branch
    ) async throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID) {
        guard let sourceConversation = await deps.persistenceDomain.modelConversation(id: sourceConversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let (newConversationID, anchorNewId, newConversation) = try await deps.persistenceDomain.persistSplitSelectingNewThread(
            sourceConversation: sourceConversation,
            atUserMessageID: messageID,
            childLineageKind: childLineageKind
        )
        let journalMessages = try await deps.persistenceDomain.messagesNeedingTranscriptMessageAppendedJournal(
            conversationID: newConversationID,
            messages: newConversation.messages
        )
        if !journalMessages.isEmpty {
            try await deps.persistenceDomain.routingAppendMessageJournalEntriesAsync(
                conversationID: newConversationID,
                messages: journalMessages
            )
        }
        await sessionProjection.syncFromRegistry(conversationID: newConversationID, conversation: newConversation)
        if adoptSelection {
            try? await orchestrator.adoptPersistedNewConversationSelection(newConversation)
        }
        return (newConversationID, anchorNewId)
    }
}

struct ConversationHarnessUtilityServiceImpl: ConversationHarnessUtilityServicing {
    let deps: ConversationRuntimeDependencies

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try await deps.persistenceDomain.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }
}

actor ConversationRunsReplayServiceImpl: ConversationRunsReplayServicing {
    nonisolated(unsafe) private var runControl: (any AgentRuntimeRunControlling)!
    private let conversationReplay: ConversationReplayService

    init(conversationReplay: ConversationReplayService) {
        self.conversationReplay = conversationReplay
    }

    nonisolated func installRunControl(_ runControl: any AgentRuntimeRunControlling) {
        precondition(self.runControl == nil, "AgentRuntimeRunControlling already installed")
        self.runControl = runControl
    }

    private var installedRunControl: any AgentRuntimeRunControlling {
        guard let runControl else {
            preconditionFailure("AgentRuntimeRunControlling not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return runControl
    }

    func cancelRun(conversationID: UUID, runID: UUID) async throws {
        try await installedRunControl.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)
    }

    func listConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await installedRunControl.listRunsForAPI(conversationID: conversationID, filter: filter)
    }

    func getConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        await installedRunControl.getRunForAPI(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: includeProjectionDetail
        )
    }

    func startConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        try await conversationReplay.serviceRuntimeStartConversationReplay(
            sourceConversationID: conversationID,
            configuration: .init(enableTools: enableTools, enableAgents: enableAgents)
        )
    }

    func stopConversationReplay(conversationID: UUID) async {
        await conversationReplay.stopConversationReplay(conversationID: conversationID)
    }

    func isConversationReplayActive(conversationID: UUID) async -> Bool {
        await conversationReplay.isConversationReplayActive(conversationID: conversationID)
    }
}

struct ConversationResidualAPIServiceImpl: ConversationResidualAPIServicing {
    let deps: ConversationRuntimeDependencies
    let orchestrationCore: AgentRuntimeOrchestrationCore
    let contextProjection: ContextProjectionService
    let runtimeLifecyclePublication: RuntimeLifecyclePublicationService
    let catalog: any ConversationCatalogServicing
    let orchestrator: OrchestratorSessionPort

    func listSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        return (try? await orchestrator.listSubAgentRegistryEntriesForAPI(conversationID: conversationID)) ?? []
    }

    func listSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry] {
        return (try? await orchestrator.listSubAgentRegistryEntriesForAPI()) ?? []
    }

    func conversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload {
        await runtimeLifecyclePublication.traceSnapshotForConversation(conversationID: conversationID)
    }

    func serverTraceSnapshot() async -> TraceTopicPayload {
        await runtimeLifecyclePublication.traceSnapshotForServer()
    }

    func listConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        guard await deps.persistenceDomain.modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        return await runtimeLifecyclePublication.listConversationTraces(
            conversationID: conversationID,
            limit: limit
        )
    }

    func snapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        await orchestrator.snapshotOrchestrationState(for: conversationID)
    }

    func projectionContextBudget(conversationID: UUID) async -> ConversationContextBudget? {
        await contextProjection.projectionContextBudgetForState(conversationID: conversationID)
    }

    func readPlanMarkdown(conversationID: UUID) async throws -> String {
        try await deps.persistenceDomain.readPlanMarkdown(for: conversationID)
    }

    func orchestratorBoundConversationID() async -> UUID? {
        await orchestrationCore.lastOrchestrationEmissionConversationID()
    }

    func previewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String?
    ) async throws -> ContextCompactionPreviewResult {
        try await contextProjection.performContextCompactionPreview(
            conversationID: conversationID,
            gating: gating,
            summarizerDebugOutputPath: summarizerDebugOutputPath
        )
    }

    func performManualContextCompaction(
        conversationID: UUID,
        reason: String?
    ) async throws -> ContextCompactionManualResult {
        try await contextProjection.performManualCompaction(
            conversationID: conversationID,
            trigger: .rest,
            reason: reason
        )
    }

    func contextCompactionManualRESTEnabled() async -> Bool {
        contextProjection.manualRESTEnabled()
    }

    func conversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? {
        guard let conversation = await catalog.getConversation(id: conversationID) else {
            return nil
        }
        let gating = await contextProjection.contextCompactionGatingResponse(for: conversation)
        return ConversationServerMetadata(contextCompactionGating: gating)
    }
}

struct ConversationDomainServiceBundle: Sendable {
    let catalog: any ConversationCatalogServicing
    let controlPlane: any ConversationControlPlaneServicing
    let lifecycle: any ConversationLifecycleServicing
    let runsReplay: any ConversationRunsReplayServicing
    let harnessUtility: any ConversationHarnessUtilityServicing
    let residualAPI: any ConversationResidualAPIServicing
}

enum ConversationDomainServiceFactory {
    static func makeBundle(
        deps: ConversationRuntimeDependencies,
        orchestrationCore: AgentRuntimeOrchestrationCore,
        orchestratorRuntime: OrchestratorRuntimeService,
        conversationReplay: ConversationReplayService,
        contextProjection: ContextProjectionService,
        runtimeLifecyclePublication: RuntimeLifecyclePublicationService,
        selection: ConversationSelectionAccessing,
        orchestrator: OrchestratorSessionPort,
        topics: ConversationTopicPublicationPort,
        messaging: ConversationMessagingPort,
        sessionProjection: SessionProjectionAccessing,
        registryOwnerAccountScope: @escaping @Sendable () -> UUID? = { nil }
    ) -> (
        bundle: ConversationDomainServiceBundle,
        controlPlane: ConversationControlPlaneServiceImpl,
        lifecycle: ConversationLifecycleServiceImpl,
        runsReplay: ConversationRunsReplayServiceImpl
    ) {
        let catalog = ConversationCatalogServiceImpl(
            deps: deps,
            selection: selection,
            registryOwnerAccountScope: registryOwnerAccountScope
        )
        let controlPlane = ConversationControlPlaneServiceImpl(
            deps: deps,
            orchestrationCore: orchestrationCore,
            orchestratorRuntime: orchestratorRuntime,
            selection: selection,
            orchestrator: orchestrator,
            topics: topics,
            messaging: messaging,
            sessionProjection: sessionProjection
        )
        let lifecycle = ConversationLifecycleServiceImpl(
            deps: deps,
            orchestratorRuntime: orchestratorRuntime,
            conversationReplay: conversationReplay,
            selection: selection,
            orchestrator: orchestrator,
            topics: topics,
            sessionProjection: sessionProjection
        )
        let runsReplay = ConversationRunsReplayServiceImpl(conversationReplay: conversationReplay)
        let bundle = ConversationDomainServiceBundle(
            catalog: catalog,
            controlPlane: controlPlane,
            lifecycle: lifecycle,
            runsReplay: runsReplay,
            harnessUtility: ConversationHarnessUtilityServiceImpl(deps: deps),
            residualAPI: ConversationResidualAPIServiceImpl(
                deps: deps,
                orchestrationCore: orchestrationCore,
                contextProjection: contextProjection,
                runtimeLifecyclePublication: runtimeLifecyclePublication,
                catalog: catalog,
                orchestrator: orchestrator
            )
        )
        return (bundle, controlPlane, lifecycle, runsReplay)
    }

    static func installRunControl(
        _ runControl: any AgentRuntimeRunControlling,
        controlPlane: ConversationControlPlaneServiceImpl,
        lifecycle: ConversationLifecycleServiceImpl,
        runsReplay: ConversationRunsReplayServiceImpl
    ) {
        controlPlane.installRunControl(runControl)
        lifecycle.installRunControl(runControl)
        runsReplay.installRunControl(runControl)
        if let agentRuntime = runControl as? AgentRuntimeSessionService {
            agentRuntime.installControlPlane(controlPlane)
        }
    }
}
