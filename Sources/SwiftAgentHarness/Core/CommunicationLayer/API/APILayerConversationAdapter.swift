//
//  Conversation API boundary adapter composed from conversation-domain services.
//

import EasyJSON
import Foundation
import SwiftAgentKit

/// API-facing conversation boundary that composes domain services and HarnessRuntimeSession-owned residual seams.
public final class APILayerConversationAdapter: APILayerConversationManaging, Sendable {
    private let catalog: any ConversationCatalogServicing
    private let controlPlane: any ConversationControlPlaneServicing
    private let lifecycle: any ConversationLifecycleServicing
    private let runsReplay: any ConversationRunsReplayServicing
    private let harnessUtility: any ConversationHarnessUtilityServicing
    private let residualAPI: any ConversationResidualAPIServicing
    private let policy: any ConversationToolModePolicyServicing
    private let subAgentLifecycle: any SubAgentLifecycleOrchestrationServicing
    private let subAgentCompletion: any SubAgentCompletionIngressServicing

    init(
        catalog: any ConversationCatalogServicing,
        controlPlane: any ConversationControlPlaneServicing,
        lifecycle: any ConversationLifecycleServicing,
        runsReplay: any ConversationRunsReplayServicing,
        harnessUtility: any ConversationHarnessUtilityServicing,
        residualAPI: any ConversationResidualAPIServicing,
        policy: any ConversationToolModePolicyServicing,
        subAgentLifecycle: any SubAgentLifecycleOrchestrationServicing,
        subAgentCompletion: any SubAgentCompletionIngressServicing
    ) {
        self.catalog = catalog
        self.controlPlane = controlPlane
        self.lifecycle = lifecycle
        self.runsReplay = runsReplay
        self.harnessUtility = harnessUtility
        self.residualAPI = residualAPI
        self.policy = policy
        self.subAgentLifecycle = subAgentLifecycle
        self.subAgentCompletion = subAgentCompletion
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        await catalog.listConversationInfo()
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        await catalog.listConversationMetadata(visibility: visibility)
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        await catalog.getConversation(id: id)
    }

    func apiGetConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? {
        await catalog.getConversationWithDerived(id: id)
    }

    func apiProjectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        try await catalog.projectConversation(conversationID: conversationID, request: request)
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        await catalog.listConversations(query: query)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        await catalog.searchConversations(query: query)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        try await controlPlane.patchConversation(conversationID: conversationID, patch: patch)
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        try await controlPlane.applyConversationRESTPatch(
            conversationID: conversationID,
            patch: patch,
            resolvedModel: resolvedModel
        )
    }

    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        await controlPlane.composeModelReferenceForRouting(
            conversationID: conversationID,
            interactionMode: interactionMode,
            clientReference: clientReference
        )
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        try await lifecycle.deleteConversation(conversationID: conversationID, hard: hard)
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        try await lifecycle.branchConversation(
            conversationID: conversationID,
            userMessageID: userMessageID,
            selectionBehavior: .adoptChild
        )
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        try await subAgentLifecycle.spawnSubAgent(
            parentConversationID: parentConversationID,
            request: request,
            modelOverride: modelOverride
        )
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        try await lifecycle.invalidateConversationCheckpoints(conversationID: conversationID, kinds: kinds)
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        await lifecycle.latestCheckpoint(conversationID: conversationID, kind: kind)
    }

    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        try await catalog.listMessagesThrowing(conversationID: conversationID)
    }

    func apiRegistryOwnerAccountID() async -> UUID? {
        await catalog.registryOwnerAccountID()
    }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        await catalog.latestTranscriptSequence(conversationID: conversationID)
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        try await catalog.readTranscriptEntries(conversationID: conversationID, request: request)
    }

    func apiConversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        try await catalog.conversationEventsBackfill(conversationID: conversationID, since: since)
    }

    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try await harnessUtility.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }

    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String] {
        try await lifecycle.listEngineArtifactKeys(conversationID: conversationID)
    }

    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data? {
        try await lifecycle.getEngineArtifact(conversationID: conversationID, key: key)
    }

    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws {
        try await lifecycle.putEngineArtifact(conversationID: conversationID, key: key, data: data)
    }

    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws {
        try await lifecycle.evictEngineArtifacts(conversationID: conversationID, key: key)
    }

    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        try await controlPlane.generateFullSystemPrompt(conversationID: conversationID, userSystemPrompt: userSystemPrompt)
    }

    func apiCreateConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        cwd: String?
    ) async throws -> UUID {
        try await controlPlane.createConversation(
            with: selectedModel,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            cwd: cwd,
            lineageKind: .root,
            origin: .user
        )
    }

    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        try await controlPlane.updateConversationMetadata(
            conversationID: conversationID,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            interactionModeChangeInitiator: "rest",
            interactionModeChangeReason: nil,
            skipControlPlaneRevisionBump: false
        )
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        try await controlPlane.updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: model,
            userSystemPrompt: userSystemPrompt
        )
    }

    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        try await policy.listAvailableTools(conversationID: conversationID)
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] {
        try await policy.listAvailableTools()
    }

    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        try await residualAPI.listSubAgentRegistryEntries(conversationID: conversationID)
    }

    func apiListSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry] {
        try await residualAPI.listSubAgentRegistryEntries()
    }

    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        await subAgentLifecycle.lifecycleSnapshot(
            conversationID: conversationID,
            pathSegments: pathSegments
        )
    }

    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload {
        await residualAPI.conversationTraceSnapshot(conversationID: conversationID)
    }

    func apiServerTraceSnapshot() async -> TraceTopicPayload {
        await residualAPI.serverTraceSnapshot()
    }

    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        try await residualAPI.listConversationTraceSpans(conversationID: conversationID, limit: limit)
    }

    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        await subAgentLifecycle.listActiveInvocations(parentConversationID: parentConversationID)
    }

    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        try await subAgentLifecycle.cancelInvocation(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        )
    }

    func apiPushCompletionAnnouncement(
        conversationID: UUID,
        announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async throws {
        guard await catalog.getConversation(id: conversationID) != nil else {
            throw APILayerConversationRouteError.conversationNotFound
        }
        await subAgentCompletion.pushCompletionAnnouncement(
            announce,
            toolMessageContent: toolMessageContent
        )
    }

    func apiResolveToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool,
        arguments: JSON? = nil
    ) async throws {
        guard await catalog.getConversation(id: conversationID) != nil else {
            throw APILayerConversationRouteError.conversationNotFound
        }
        try await policy.resolveToolApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            durable: durable,
            arguments: arguments
        )
    }

    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        try await policy.listAvailableSkills(conversationID: conversationID)
    }

    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] {
        try await policy.listAvailableSkills()
    }

    func apiListModeProfiles() async throws -> [ModeProfilePickerRow] {
        try await policy.listModeProfiles()
    }

    func apiReloadModeProfiles() async throws -> Bool {
        try await policy.reloadModeProfiles()
    }

    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        try await policy.listSlashCommands(conversationID: conversationID)
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        try await controlPlane.updateConversationThinkingConfig(conversationID: conversationID, thinkingConfig: thinkingConfig)
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        try await lifecycle.copyConversation(from: sourceConversationID, to: model, systemPrompt: systemPrompt)
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        await residualAPI.snapshotOrchestrationState(conversationID: conversationID)
    }

    func apiProjectionContextBudget(conversationID: UUID) async -> ConversationContextBudget? {
        await residualAPI.projectionContextBudget(conversationID: conversationID)
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        try await residualAPI.readPlanMarkdown(conversationID: conversationID)
    }

    func apiOrchestratorBoundConversationID() async -> UUID? {
        await residualAPI.orchestratorBoundConversationID()
    }

    func apiPreviewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String? = nil
    ) async throws -> ContextCompactionPreviewResult {
        try await residualAPI.previewContextCompaction(
            conversationID: conversationID,
            gating: gating,
            summarizerDebugOutputPath: summarizerDebugOutputPath
        )
    }

    func apiPerformManualContextCompaction(
        conversationID: UUID,
        reason: String? = nil
    ) async throws -> ContextCompactionManualResult {
        try await residualAPI.performManualContextCompaction(
            conversationID: conversationID,
            reason: reason
        )
    }

    func apiContextCompactionManualRESTEnabled() async -> Bool {
        await residualAPI.contextCompactionManualRESTEnabled()
    }

    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? {
        await residualAPI.conversationServerMetadata(conversationID: conversationID)
    }
}
