//
//  distinct ``APILayerConversationManaging`` / ``APILayerChatRuntimeManaging`` instances
//  forwarding to one ``HarnessRuntimeSession``.
//

import EasyJSON
import Foundation
import SwiftAgentKit

/// Conversation control-plane projection for the gateway; forwards to any ``APILayerConversationManaging`` backend (typically ``HarnessRuntimeSession`` until peel completes).
final class ConversationSessionService: APILayerConversationManaging, Sendable {
    private let backend: any APILayerConversationManaging

    init(backend: any APILayerConversationManaging) {
        self.backend = backend
    }

    /// Maps conversation-not-found errors to ``APILayerConversationRouteError`` without relying on concrete backend types.
    private func mapConversationNotFound<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if APILayerConversationRouteError.representsConversationNotFound(error) {
                throw APILayerConversationRouteError.conversationNotFound
            }
            throw error
        }
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        await backend.apiListConversationInfo()
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        await backend.apiListConversationMetadata(visibility: visibility)
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        await backend.apiGetConversation(id: id)
    }

    func apiGetConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? {
        await backend.apiGetConversationWithDerived(id: id)
    }

    func apiProjectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        try await mapConversationNotFound {
            try await backend.apiProjectConversation(conversationID: conversationID, request: request)
        }
    }

    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        try await mapConversationNotFound { try await backend.apiListMessagesThrowing(conversationID: conversationID) }
    }

    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        try await mapConversationNotFound { try await backend.apiGenerateFullSystemPrompt(conversationID: conversationID, withUserSystemPrompt: userSystemPrompt) }
    }

    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode, modeProfileID: String?, cwd: String?) async throws -> UUID {
        try await mapConversationNotFound {
            try await backend.apiCreateConversation(with: selectedModel, userSystemPrompt: userSystemPrompt, topic: topic, description: description, metadata: metadata, interactionMode: interactionMode, modeProfileID: modeProfileID, cwd: cwd)
        }
    }

    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        try await mapConversationNotFound {
            try await backend.apiUpdateConversationMetadata(conversationID: conversationID, topic: topic, description: description, metadata: metadata, interactionMode: interactionMode, modeProfileID: modeProfileID)
        }
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        try await mapConversationNotFound {
            try await backend.apiUpdateConversationModelAndUserPrompt(conversationID: conversationID, model: model, userSystemPrompt: userSystemPrompt)
        }
    }

    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        try await mapConversationNotFound { try await backend.apiListAvailableTools(conversationID: conversationID) }
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] {
        try await backend.apiListAvailableTools()
    }

    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        try await mapConversationNotFound { try await backend.apiListSubAgentRegistryEntries(conversationID: conversationID) }
    }

    func apiListSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry] {
        try await backend.apiListSubAgentRegistryEntries()
    }

    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        await backend.apiSubAgentLifecycleSnapshot(conversationID: conversationID, pathSegments: pathSegments)
    }

    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload {
        await backend.apiConversationTraceSnapshot(conversationID: conversationID)
    }

    func apiServerTraceSnapshot() async -> TraceTopicPayload {
        await backend.apiServerTraceSnapshot()
    }

    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        try await mapConversationNotFound {
            try await backend.apiListConversationTraceSpans(conversationID: conversationID, limit: limit)
        }
    }

    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        await backend.apiListActiveSubAgentInvocations(parentConversationID: parentConversationID)
    }

    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        try await mapConversationNotFound {
            try await backend.apiCancelActiveSubAgentInvocation(
                parentConversationID: parentConversationID,
                lifecycleID: lifecycleID
            )
        }
    }

    func apiPushCompletionAnnouncement(
        conversationID: UUID,
        announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async throws {
        try await mapConversationNotFound {
            try await backend.apiPushCompletionAnnouncement(
                conversationID: conversationID,
                announce: announce,
                toolMessageContent: toolMessageContent
            )
        }
    }

    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        try await mapConversationNotFound { try await backend.apiListAvailableSkills(conversationID: conversationID) }
    }

    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] {
        try await backend.apiListAvailableSkills()
    }

    func apiListModeProfiles() async throws -> [ModeProfilePickerRow] {
        try await backend.apiListModeProfiles()
    }

    func apiReloadModeProfiles() async throws -> Bool {
        try await backend.apiReloadModeProfiles()
    }

    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        try await mapConversationNotFound { try await backend.apiListSlashCommands(conversationID: conversationID) }
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        try await mapConversationNotFound {
            try await backend.apiUpdateConversationThinkingConfig(conversationID: conversationID, thinkingConfig: thinkingConfig)
        }
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        try await mapConversationNotFound {
            try await backend.apiCopyConversation(from: sourceConversationID, to: model, systemPrompt: systemPrompt)
        }
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        try await mapConversationNotFound { try await backend.apiDeleteConversation(conversationID: conversationID, hard: hard) }
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        await backend.apiListConversations(query: query)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        await backend.apiSearchConversations(query: query)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        try await mapConversationNotFound { try await backend.apiPatchConversation(conversationID: conversationID, patch: patch) }
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        try await mapConversationNotFound {
            try await backend.apiApplyConversationRESTPatch(conversationID: conversationID, patch: patch, resolvedModel: resolvedModel)
        }
    }

    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        await backend.apiComposeModelReferenceForRouting(conversationID: conversationID, interactionMode: interactionMode, clientReference: clientReference)
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        try await mapConversationNotFound {
            try await backend.apiBranchConversation(conversationID: conversationID, userMessageID: userMessageID)
        }
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        try await mapConversationNotFound {
            try await backend.apiSpawnSubAgent(parentConversationID: parentConversationID, request: request, modelOverride: modelOverride)
        }
    }

    func apiResolveToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool
    ) async throws {
        try await mapConversationNotFound {
            try await backend.apiResolveToolApproval(
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

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        try await mapConversationNotFound {
            try await backend.apiInvalidateConversationCheckpoints(conversationID: conversationID, kinds: kinds)
        }
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        await backend.apiGetLatestCheckpoint(conversationID: conversationID, kind: kind)
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        await backend.apiSnapshotOrchestrationState(conversationID: conversationID)
    }

    func apiProjectionContextBudget(conversationID: UUID) async -> ConversationContextBudget? {
        await backend.apiProjectionContextBudget(conversationID: conversationID)
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        try await mapConversationNotFound { try await backend.apiReadPlanMarkdown(conversationID: conversationID) }
    }

    func apiOrchestratorBoundConversationID() async -> UUID? {
        await backend.apiOrchestratorBoundConversationID()
    }

    func apiPreviewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String?
    ) async throws -> ContextCompactionPreviewResult {
        try await mapConversationNotFound {
            try await backend.apiPreviewContextCompaction(
                conversationID: conversationID,
                gating: gating,
                summarizerDebugOutputPath: summarizerDebugOutputPath
            )
        }
    }

    func apiPerformManualContextCompaction(
        conversationID: UUID,
        reason: String?
    ) async throws -> ContextCompactionManualResult {
        try await mapConversationNotFound {
            try await backend.apiPerformManualContextCompaction(conversationID: conversationID, reason: reason)
        }
    }

    func apiContextCompactionManualRESTEnabled() async -> Bool {
        await backend.apiContextCompactionManualRESTEnabled()
    }

    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? {
        await backend.apiGetConversationServerMetadata(conversationID: conversationID)
    }

    func apiRegistryOwnerAccountID() async -> UUID? {
        await backend.apiRegistryOwnerAccountID()
    }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        await backend.apiLatestTranscriptSequence(conversationID: conversationID)
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        try await backend.apiReadTranscriptEntries(conversationID: conversationID, request: request)
    }

    func apiConversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        try await backend.apiConversationEventsBackfill(conversationID: conversationID, since: since)
    }

    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try await backend.apiHarnessDedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }

    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String] {
        try await mapConversationNotFound { try await backend.apiListEngineArtifactKeys(conversationID: conversationID) }
    }

    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data? {
        try await mapConversationNotFound { try await backend.apiGetEngineArtifact(conversationID: conversationID, key: key) }
    }

    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws {
        try await mapConversationNotFound { try await backend.apiPutEngineArtifact(conversationID: conversationID, key: key, data: data) }
    }

    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws {
        try await mapConversationNotFound { try await backend.apiEvictEngineArtifacts(conversationID: conversationID, key: key) }
    }
}

/// Streaming / replay / cancellation projection for the gateway; forwards to any ``APILayerChatRuntimeManaging`` backend (typically ``RuntimeStreamingOrchestrationService``).
final class ChatRuntimeService: APILayerChatRuntimeManaging, Sendable {
    private let backend: any APILayerChatRuntimeManaging

    init(backend: any APILayerChatRuntimeManaging) {
        self.backend = backend
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await backend.apiMessageStream(for: conversationID)
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass? = nil,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil
    ) async throws -> ChatStreamResponse {
        try await backend.apiSendMessageAndStreamResponse(
            conversationID: conversationID,
            text,
            images: images,
            enableTools: enableTools,
            enableAgents: enableAgents,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            inputTrustRaw: inputTrustRaw,
            resolvedInputTrustClass: resolvedInputTrustClass,
            systemReminder: systemReminder,
            originSurface: originSurface,
            originSenderID: originSenderID
        )
    }

    func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await backend.apiRevertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: messageID,
            enableTools: enableTools,
            enableAgents: enableAgents
        )
    }

    func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        try await backend.apiSplitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            enableTools: enableTools,
            enableAgents: enableAgents
        )
    }

    func apiCancelMessageStream() async {
        await backend.apiCancelMessageStream()
    }

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        await backend.apiSetOrchestrationStateOutOfBandPush(id: id, push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        await backend.apiClearOrchestrationStateOutOfBandPush(id: id)
    }

    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        try await backend.apiStartConversationReplay(conversationID: conversationID, enableTools: enableTools, enableAgents: enableAgents)
    }

    func apiStopConversationReplay(conversationID: UUID) async {
        await backend.apiStopConversationReplay(conversationID: conversationID)
    }

    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool {
        await backend.apiIsConversationReplayActive(conversationID: conversationID)
    }

    func apiRequestTurnLoopStop(conversationID: UUID) async {
        await backend.apiRequestTurnLoopStop(conversationID: conversationID)
    }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        try await backend.apiCancelRun(conversationID: conversationID, runID: runID)
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await backend.apiListConversationRuns(conversationID: conversationID, filter: filter)
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        await backend.apiGetConversationRun(conversationID: conversationID, runID: runID, includeProjectionDetail: includeProjectionDetail)
    }
}
