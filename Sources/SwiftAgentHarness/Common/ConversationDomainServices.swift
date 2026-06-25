import EasyJSON
import Foundation
import SwiftAgentKit

protocol ConversationCatalogServicing: Sendable {
    func listConversationInfo() async -> [ModelConversation]
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata]
    func getConversation(id: UUID) async -> ModelConversation?
    func getConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse?
    func projectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse
    func listConversations(query: ConversationListQuery) async -> PagedConversationsResponse
    func searchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse
    func listMessagesThrowing(conversationID: UUID) async throws -> [Message]
    func latestTranscriptSequence(conversationID: UUID) async -> Int?
    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry]
    func conversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse
    func registryOwnerAccountID() async -> UUID?
}

protocol ConversationControlPlaneServicing: Sendable {
    func patchConversation(conversationID: UUID, patch: ConversationPatch) async throws
    func applyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64
    func composeModelReferenceForRouting(
        conversationID: UUID?,
        interactionMode: InteractionMode?,
        clientReference: ModelReference
    ) async -> ModelReference
    func generateFullSystemPrompt(conversationID: UUID?, userSystemPrompt: String?) async throws -> String
    func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        cwd: String?,
        lineageKind: ConversationLineageKind,
        origin: ConversationOrigin
    ) async throws -> UUID
    func updateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode?,
        modeProfileID: String?,
        interactionModeChangeInitiator: String?,
        interactionModeChangeReason: String?,
        skipControlPlaneRevisionBump: Bool
    ) async throws
    func updateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws
    func updateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws
    func flushPendingModeTransition(
        conversationID: UUID,
        runID: UUID,
        terminalCategory: ConversationRunTerminalCategory?
    ) async
    func scheduleOrApplyToolModeTransition(
        conversationID: UUID,
        targetMode: InteractionMode,
        modeProfileID: String,
        reason: String
    ) async throws -> ModeTransitionApplyResult
}

extension ConversationControlPlaneServicing {
    func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        cwd: String? = nil
    ) async throws -> UUID {
        try await createConversation(
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
}

enum BranchSelectionBehavior: Sendable {
    case adoptChild
    case preserveForeground
}

protocol ConversationLifecycleServicing: Sendable {
    func deleteConversation(conversationID: UUID, hard: Bool) async throws
    func branchConversation(
        conversationID: UUID,
        userMessageID: UUID,
        selectionBehavior: BranchSelectionBehavior,
        childLineageKind: ConversationLineageKind
    ) async throws -> UUID
    func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID
    func invalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws
    func latestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse?
    func listEngineArtifactKeys(conversationID: UUID) async throws -> [String]
    func getEngineArtifact(conversationID: UUID, key: String) async throws -> Data?
    func putEngineArtifact(conversationID: UUID, key: String, data: Data) async throws
    func evictEngineArtifacts(conversationID: UUID, key: String?) async throws
    func persistSplitSelectingNewThread(
        sourceConversationID: UUID,
        atUserMessageID: UUID,
        adoptSelection: Bool,
        childLineageKind: ConversationLineageKind
    ) async throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID)
}

extension ConversationLifecycleServicing {
    func branchConversation(
        conversationID: UUID,
        userMessageID: UUID,
        selectionBehavior: BranchSelectionBehavior
    ) async throws -> UUID {
        try await branchConversation(
            conversationID: conversationID,
            userMessageID: userMessageID,
            selectionBehavior: selectionBehavior,
            childLineageKind: .branch
        )
    }

    func persistSplitSelectingNewThread(
        sourceConversationID: UUID,
        atUserMessageID: UUID,
        adoptSelection: Bool
    ) async throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID) {
        try await persistSplitSelectingNewThread(
            sourceConversationID: sourceConversationID,
            atUserMessageID: atUserMessageID,
            adoptSelection: adoptSelection,
            childLineageKind: .branch
        )
    }
}

protocol ConversationRunsReplayServicing: Sendable {
    func cancelRun(conversationID: UUID, runID: UUID) async throws
    func listConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse
    func getConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo?
    func startConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws
    func stopConversationReplay(conversationID: UUID) async
    func isConversationReplayActive(conversationID: UUID) async -> Bool
}

protocol ConversationHarnessUtilityServicing: Sendable {
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool
}

protocol ConversationResidualAPIServicing: Sendable {
    func listSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry]
    func listSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry]
    func conversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload
    func serverTraceSnapshot() async -> TraceTopicPayload
    func listConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse
    func snapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState?
    func projectionContextBudget(conversationID: UUID) async -> ConversationContextBudget?
    func readPlanMarkdown(conversationID: UUID) async throws -> String
    func orchestratorBoundConversationID() async -> UUID?
    func previewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String?
    ) async throws -> ContextCompactionPreviewResult
    func performManualContextCompaction(
        conversationID: UUID,
        reason: String?
    ) async throws -> ContextCompactionManualResult
    func contextCompactionManualRESTEnabled() async -> Bool
    func conversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata?
}

protocol ConversationToolModePolicyServicing: Sendable {
    func listAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo]
    func listAvailableTools() async throws -> [AvailableToolInfo]
    func listAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo]
    func listAvailableSkills() async throws -> [AvailableSkillInfo]
    func listModeProfiles() async throws -> [ModeProfilePickerRow]
    func reloadModeProfiles() async throws -> Bool
    func listSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry]
    func resolveToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool
    ) async
}

protocol ConversationToolModePolicyOwning: Sendable {
    func listAvailableToolsForAPI(conversationID: UUID) async throws -> [AvailableToolInfo]
    func listAvailableToolsForAPI() async throws -> [AvailableToolInfo]
    func listAvailableSkillsForAPI(conversationID: UUID) async throws -> [AvailableSkillInfo]
    func listAvailableSkillsForAPI() async throws -> [AvailableSkillInfo]
    func listModeProfilesForAPI() async throws -> [ModeProfilePickerRow]
    func reloadModeProfilesForAPI() async throws -> Bool
    func listSlashCommandsForAPI(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry]
    func resolveToolApprovalForAPI(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool
    ) async
}

struct ConversationToolModePolicyService: ConversationToolModePolicyServicing {
    let owner: any ConversationToolModePolicyOwning

    func listAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        try await owner.listAvailableToolsForAPI(conversationID: conversationID)
    }

    func listAvailableTools() async throws -> [AvailableToolInfo] {
        try await owner.listAvailableToolsForAPI()
    }

    func listAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        try await owner.listAvailableSkillsForAPI(conversationID: conversationID)
    }

    func listAvailableSkills() async throws -> [AvailableSkillInfo] {
        try await owner.listAvailableSkillsForAPI()
    }

    func listModeProfiles() async throws -> [ModeProfilePickerRow] {
        try await owner.listModeProfilesForAPI()
    }

    func reloadModeProfiles() async throws -> Bool {
        try await owner.reloadModeProfilesForAPI()
    }

    func listSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        try await owner.listSlashCommandsForAPI(conversationID: conversationID)
    }

    func resolveToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool
    ) async {
        await owner.resolveToolApprovalForAPI(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            durable: durable
        )
    }
}
