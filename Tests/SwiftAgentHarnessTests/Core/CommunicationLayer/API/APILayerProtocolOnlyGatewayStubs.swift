import EasyJSON
import Foundation
import SwiftAgentKit
@testable import SwiftAgentHarness

final class ProtocolOnlyConversationGatewayStub: APILayerConversationManaging, Sendable {
    private let defaultSystemPrompt: String
    private let tools: [AvailableToolInfo]
    private let conversationScopedTools: [AvailableToolInfo]?
    private let skills: [AvailableSkillInfo]
    private let conversationScopedSkills: [AvailableSkillInfo]?
    private let subAgents: [SubAgentRegistryEntry]
    private let modeProfiles: [ModeProfilePickerRow]
    private let branchRouteError: APILayerConversationRouteError?
    private let resolveToolApprovalRouteError: APILayerConversationRouteError?
    private let previewContextCompactionResult: ContextCompactionPreviewResult?
    private let conversationsByID: [UUID: ModelConversation]

    init(
        defaultSystemPrompt: String = "",
        tools: [AvailableToolInfo] = [],
        conversationScopedTools: [AvailableToolInfo]? = nil,
        skills: [AvailableSkillInfo] = [],
        conversationScopedSkills: [AvailableSkillInfo]? = nil,
        subAgents: [SubAgentRegistryEntry] = [],
        modeProfiles: [ModeProfilePickerRow] = [],
        branchRouteError: APILayerConversationRouteError? = nil,
        resolveToolApprovalRouteError: APILayerConversationRouteError? = nil,
        previewContextCompactionResult: ContextCompactionPreviewResult? = nil,
        conversationsByID: [UUID: ModelConversation] = [:]
    ) {
        self.defaultSystemPrompt = defaultSystemPrompt
        self.tools = tools
        self.conversationScopedTools = conversationScopedTools
        self.skills = skills
        self.conversationScopedSkills = conversationScopedSkills
        self.subAgents = subAgents
        self.modeProfiles = modeProfiles
        self.branchRouteError = branchRouteError
        self.resolveToolApprovalRouteError = resolveToolApprovalRouteError
        self.previewContextCompactionResult = previewContextCompactionResult
        self.conversationsByID = conversationsByID
    }

    func apiListConversationInfo() async -> [ModelConversation] { [] }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func apiGetConversation(id: UUID) async -> ModelConversation? { conversationsByID[id] }
    func apiGetConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? { nil }
    func apiProjectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        _ = (conversationID, request)
        throw APILayerConversationAPIError.unsupported
    }
    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        _ = conversationID
        return []
    }
    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        userSystemPrompt ?? defaultSystemPrompt
    }
    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode, modeProfileID: String?, cwd: String?) async throws -> UUID {
        _ = (selectedModel, userSystemPrompt, topic, description, metadata, interactionMode, modeProfileID, cwd)
        return UUID()
    }
    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        _ = (conversationID, topic, description, metadata, interactionMode, modeProfileID)
    }
    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
    }
    func apiListAvailableTools() async throws -> [AvailableToolInfo] { tools }
    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        _ = conversationID
        return conversationScopedTools ?? tools
    }
    func apiListSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry] { subAgents }
    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] { _ = conversationID; return subAgents }
    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        _ = pathSegments
        return SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
    }
    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload { _ = conversationID; return TraceTopicPayload(spans: []) }
    func apiServerTraceSnapshot() async -> TraceTopicPayload { TraceTopicPayload(spans: []) }
    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse { _ = limit; return ConversationTraceResponse(conversationID: conversationID, spans: []) }
    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] { _ = parentConversationID; return [] }
    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws { _ = (parentConversationID, lifecycleID) }
    func apiPushCompletionAnnouncement(conversationID: UUID, announce: CompletionAnnouncePayload, toolMessageContent: String?) async throws { _ = (conversationID, announce, toolMessageContent) }
    func apiResolveToolApproval(conversationID: UUID, runID: UUID?, toolName: String, route: ToolApprovalRoute, status: ToolApprovalResolutionStatus, source: String, reason: String?, durable: Bool, arguments: JSON?) async throws {
        _ = (conversationID, runID, toolName, route, status, source, reason, durable)
        if let resolveToolApprovalRouteError {
            throw resolveToolApprovalRouteError
        }
    }
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] { skills }
    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        _ = conversationID
        return conversationScopedSkills ?? skills
    }
    func apiListModeProfiles() async throws -> [ModeProfilePickerRow] { modeProfiles }
    func apiReloadModeProfiles() async throws -> Bool { false }
    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] { _ = conversationID; return [] }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws { _ = (conversationID, routingPolicyTools) }
    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws { _ = (conversationID, routingPolicySkills) }
    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws { _ = (conversationID, thinkingConfig) }
    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID { _ = (sourceConversationID, model, systemPrompt); return UUID() }
    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws { _ = (conversationID, hard) }
    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse { _ = query; return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil) }
    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse { _ = query; return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil) }
    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws { _ = (conversationID, patch) }
    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference { clientReference }
    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 { _ = (conversationID, patch, resolvedModel); return 0 }
    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        _ = (conversationID, userMessageID)
        if let branchRouteError {
            throw branchRouteError
        }
        return UUID()
    }
    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID { _ = (parentConversationID, request, modelOverride); return UUID() }
    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws { _ = (conversationID, kinds) }
    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? { _ = (conversationID, kind); return nil }
    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? { _ = conversationID; return nil }
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String { _ = conversationID; return "" }
    func apiOrchestratorBoundConversationID() async -> UUID? { nil }
    func apiPreviewContextCompaction(conversationID: UUID, gating: ContextCompactionGatingOptions, summarizerDebugOutputPath: String?) async throws -> ContextCompactionPreviewResult {
        _ = (conversationID, gating, summarizerDebugOutputPath)
        if let previewContextCompactionResult {
            return previewContextCompactionResult
        }
        throw APILayerChatPreviewError.notSupported
    }
    func apiPerformManualContextCompaction(conversationID: UUID, reason: String?) async throws -> ContextCompactionManualResult {
        _ = (conversationID, reason)
        throw APILayerChatPreviewError.notSupported
    }
    func apiContextCompactionManualRESTEnabled() async -> Bool { false }
    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? { _ = conversationID; return nil }
    func apiRegistryOwnerAccountID() async -> UUID? { nil }
    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? { _ = conversationID; return nil }
    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] { _ = (conversationID, request); return [] }
    func apiConversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        ConversationEventsBackfillResponse(
            conversationID: conversationID,
            since: since,
            latestSeq: 0,
            lagging: false,
            events: []
        )
    }
    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { _ = (key, ttlSeconds); return true }
    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String] { _ = conversationID; throw APILayerConversationAPIError.unsupported }
    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data? { _ = (conversationID, key); throw APILayerConversationAPIError.unsupported }
    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws { _ = (conversationID, key, data); throw APILayerConversationAPIError.unsupported }
    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws { _ = (conversationID, key); throw APILayerConversationAPIError.unsupported }
}

final class ProtocolOnlyRuntimeGatewayStub: APILayerChatRuntimeManaging, Sendable {
    private let revertRouteError: APILayerConversationRouteError?
    private let splitRouteError: APILayerConversationRouteError?
    private let cancelRunRouteError: APILayerConversationRouteError?

    init(
        revertRouteError: APILayerConversationRouteError? = nil,
        splitRouteError: APILayerConversationRouteError? = nil,
        cancelRunRouteError: APILayerConversationRouteError? = nil
    ) {
        self.revertRouteError = revertRouteError
        self.splitRouteError = splitRouteError
        self.cancelRunRouteError = cancelRunRouteError
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> { _ = conversationID; return AsyncStream { $0.finish() } }
    func apiSendMessageAndStreamResponse(conversationID: UUID, _ text: String, images: [Message.Image], enableTools: Bool, enableAgents: Bool, expectedPreviousTailHarnessMessageID: UUID?, inputTrustRaw: String?, resolvedInputTrustClass: TrustPolicyClass? = nil, systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil
    ) async throws -> ChatStreamResponse {
        _ = (conversationID, text, images, enableTools, enableAgents, expectedPreviousTailHarnessMessageID, inputTrustRaw, resolvedInputTrustClass, systemReminder)
        throw APILayerConversationAPIError.unsupported
    }
    func apiRevertToUserMessageAndStreamResponse(conversationID: UUID, messageID: UUID, enableTools: Bool, enableAgents: Bool) async throws -> ChatStreamResponse {
        _ = (conversationID, messageID, enableTools, enableAgents)
        if let revertRouteError {
            throw revertRouteError
        }
        throw APILayerConversationAPIError.unsupported
    }
    func apiSplitConversationAtUserMessage(conversationID: UUID, messageID: UUID, enableTools: Bool, enableAgents: Bool) async throws -> ChatStreamResponse {
        _ = (conversationID, messageID, enableTools, enableAgents)
        if let splitRouteError {
            throw splitRouteError
        }
        throw APILayerConversationAPIError.unsupported
    }
    func apiCancelMessageStream() async {}
    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async { _ = (id, push) }
    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async { _ = id }
    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        _ = (conversationID, enableTools, enableAgents)
        throw APILayerConversationAPIError.unsupported
    }
    func apiStopConversationReplay(conversationID: UUID) async { _ = conversationID }
    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool { _ = conversationID; return false }
    func apiRequestTurnLoopStop(conversationID: UUID) async { _ = conversationID }
    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
        if let cancelRunRouteError {
            throw cancelRunRouteError
        }
    }
    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse { _ = (conversationID, filter); return ConversationRunListResponse(runs: []) }
    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? { _ = (conversationID, runID, includeProjectionDetail); return nil }
}
