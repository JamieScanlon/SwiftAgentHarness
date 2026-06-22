import Foundation
import EasyJSON
import SwiftAgentKit
import Testing
import VaporTesting
@testable import SwiftAgentHarness

private final class StreamingStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]

    init(models: [Model] = []) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] {
        models
    }
}

/// Shared mutable state for split ``FakeStreamingConversationDouble`` / ``FakeStreamingRuntimeDouble`` (matches production gateway separation).
private actor FakeStreamingChatStore {
    private var validConversationIDs: Set<UUID>
    private var selectedConversationID: UUID?
    private var sentTexts: [String] = []
    private let streamChunks: [String]
    private let throwOnSend: Bool
    private let conflictOnSend: ConversationServiceError?
    private var messages: [Message]

    init(
        validConversationIDs: [UUID],
        initialMessages: [Message] = [],
        streamChunks: [String] = ["chunk-1", "chunk-2", "chunk-3"],
        throwOnSend: Bool = false,
        conflictOnSend: ConversationServiceError? = nil
    ) {
        self.validConversationIDs = Set(validConversationIDs)
        self.selectedConversationID = validConversationIDs.first
        self.streamChunks = streamChunks
        self.throwOnSend = throwOnSend
        self.conflictOnSend = conflictOnSend
        self.messages = initialMessages
    }

    func lastSentText() -> String? {
        sentTexts.last
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        validConversationIDs.map { id in
            ModelConversation(id: id, model: Self.model, messages: [])
        }
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        let nowStr = isoFormatter.string(from: now)
        return validConversationIDs.map { id in
            ConversationMetadata(
                id: id.uuidString,
                modelName: Self.model.modelName,
                topic: nil,
                description: nil,
                messageCount: 0,
                createdAt: nowStr,
                updatedAt: nowStr
            )
        }
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        guard validConversationIDs.contains(id) else { return nil }
        return ModelConversation(id: id, model: Self.model, messages: messages)
    }

    func apiListCurrentMessages() async -> [Message] {
        messages
    }

    func apiListCurrentMessagesThrowing() async throws -> [Message] {
        messages
    }

    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        return messages
    }

    func apiRegistryOwnerAccountID() async -> UUID? { nil }

    func apiGenerateFullSystemPrompt(withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        userSystemPrompt ?? "system"
    }

    func apiSelectConversation(conversationID: UUID) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        selectedConversationID = conversationID
    }

    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode, modeProfileID: String?) async throws {
        let id = UUID()
        validConversationIDs.insert(id)
        selectedConversationID = id
        _ = (selectedModel, userSystemPrompt, topic, description, metadata, interactionMode, modeProfileID)
    }

    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        _ = (topic, description, metadata, interactionMode, modeProfileID)
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] {
        []
    }

    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] {
        []
    }

    func apiListSlashCommands() async throws -> [SlashCommandAutocompleteEntry] {
        []
    }

    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws {
        guard validConversationIDs.contains(sourceConversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "source conversation not found"])
        }
        let newID = UUID()
        validConversationIDs.insert(newID)
        selectedConversationID = newID
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        let _ = hard
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        validConversationIDs.remove(conversationID)
        if selectedConversationID == conversationID {
            selectedConversationID = validConversationIDs.first
        }
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = Date()
        let nowStr = iso.string(from: now)
        let ids = Array(validConversationIDs)
        let items = ids.map { id in
            ConversationListSummary(
                id: id,
                modelName: Self.model.modelName,
                topic: nil,
                description: nil,
                messageCount: 0,
                createdAt: nowStr,
                updatedAt: nowStr,
                lifecycle: .active,
                tags: []
            )
        }
        let _ = query
        return PagedConversationsResponse(items: items, totalCount: items.count, nextOffset: nil)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        let _ = query
        return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        let _ = patch
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        let _ = (patch, resolvedModel)
        return 1
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        let _ = userMessageID
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        return UUID()
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        guard validConversationIDs.contains(parentConversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        let newID = UUID()
        validConversationIDs.insert(newID)
        selectedConversationID = newID
        let _ = (request, modelOverride)
        return newID
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        let _ = kinds
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        let _ = (conversationID, kind)
        return nil
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        AsyncStream { continuation in
            continuation.yield(messages)
            continuation.finish()
        }
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil
    ) async throws -> ChatStreamResponse {
        _ = (images, enableTools, enableAgents, expectedPreviousTailHarnessMessageID, inputTrustRaw, systemReminder)
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        if let conflictOnSend {
            throw conflictOnSend
        }
        if throwOnSend {
            throw NSError(domain: "FakeStreamingChatStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "simulated stream failure"])
        }

        sentTexts.append(text)
        let messageID = UUID()
        let runID = UUID()
        messages.append(Message(id: messageID, role: .user, content: text, inputTrustRaw: inputTrustRaw))
        messages.append(Message(id: UUID(), role: .assistant, content: streamChunks.joined()))
        let chunks = streamChunks
        let partialContent = AsyncStream<ChatStreamingPartial> { continuation in
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            continuation.finish()
        }
        let orchestrationState = AsyncStream { continuation in
            continuation.yield(
                ConversationOrchestrationState(
                    llmRuntimePhase: .idleReady,
                    agenticPhase: .idle
                )
            )
            continuation.finish()
        }
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: orchestrationState,
            conversationID: conversationID,
            runID: runID,
            messageID: messageID
        )
    }

    func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        _ = (enableTools, enableAgents)
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        if throwOnSend {
            throw NSError(domain: "FakeStreamingChatStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "simulated stream failure"])
        }
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages = Array(messages[...idx])
        }
        messages.append(Message(id: UUID(), role: .assistant, content: streamChunks.joined()))
        let chunks = streamChunks
        let partialContent = AsyncStream<ChatStreamingPartial> { continuation in
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            continuation.finish()
        }
        let orchestrationState = AsyncStream { continuation in
            continuation.yield(
                ConversationOrchestrationState(
                    llmRuntimePhase: .idleReady,
                    agenticPhase: .idle
                )
            )
            continuation.finish()
        }
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: orchestrationState,
            conversationID: conversationID
        )
    }

    func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        _ = (conversationID, enableTools, enableAgents)
        if throwOnSend {
            throw NSError(domain: "FakeStreamingChatStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "simulated stream failure"])
        }
        let newID = UUID()
        validConversationIDs.insert(newID)
        selectedConversationID = newID
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            messages = Array(messages[...idx])
        }
        messages.append(Message(id: UUID(), role: .assistant, content: streamChunks.joined()))
        let chunks = streamChunks
        let partialContent = AsyncStream<ChatStreamingPartial> { continuation in
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            continuation.finish()
        }
        let orchestrationState = AsyncStream { continuation in
            continuation.yield(
                ConversationOrchestrationState(
                    llmRuntimePhase: .idleReady,
                    agenticPhase: .idle
                )
            )
            continuation.finish()
        }
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: orchestrationState,
            conversationID: newID
        )
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {}

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {}

    func apiStartConversationReplay(enableTools: Bool, enableAgents: Bool) async throws {}

    func apiStopConversationReplay() async {}

    func apiIsConversationReplayActive() async -> Bool { false }

    func apiRequestTurnLoopStop() async {}

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
    }
    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        _ = (conversationID, filter)
        return ConversationRunListResponse(runs: [])
    }
    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? { nil }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        guard selectedConversationID == conversationID else { return nil }
        return ConversationOrchestrationState(
            llmRuntimePhase: .idleReady,
            agenticPhase: .idle,
            llmRequestPhase: nil
        )
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        return ""
    }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        guard validConversationIDs.contains(conversationID) else { return nil }
        return 0
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = request
        guard validConversationIDs.contains(conversationID) else {
            throw NSError(domain: "FakeStreamingChatStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        return []
    }

    var currentConversationID: UUID? {
        get async { selectedConversationID }
    }

    private static var model: Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "fake-stream-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

private final class FakeStreamingConversationDouble: APILayerConversationManaging, Sendable {
    private let store: FakeStreamingChatStore

    init(store: FakeStreamingChatStore) {
        self.store = store
    }

    func apiListConversationInfo() async -> [ModelConversation] { await store.apiListConversationInfo() }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { await store.apiListConversationMetadata(visibility: visibility) }
    func apiGetConversation(id: UUID) async -> ModelConversation? { await store.apiGetConversation(id: id) }
    func apiListCurrentMessages() async -> [Message] { await store.apiListCurrentMessages() }
    func apiListCurrentMessagesThrowing() async throws -> [Message] { try await store.apiListCurrentMessagesThrowing() }
    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        try await store.apiListMessagesThrowing(conversationID: conversationID)
    }

    func apiRegistryOwnerAccountID() async -> UUID? {
        await store.apiRegistryOwnerAccountID()
    }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        await store.apiLatestTranscriptSequence(conversationID: conversationID)
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        try await store.apiReadTranscriptEntries(conversationID: conversationID, request: request)
    }

    func apiGenerateFullSystemPrompt(withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        try await store.apiGenerateFullSystemPrompt(withUserSystemPrompt: userSystemPrompt)
    }

    func apiSelectConversation(conversationID: UUID) async throws { try await store.apiSelectConversation(conversationID: conversationID) }
    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode, modeProfileID: String?) async throws {
        try await store.apiCreateConversation(with: selectedModel, userSystemPrompt: userSystemPrompt, topic: topic, description: description, metadata: metadata, interactionMode: interactionMode, modeProfileID: modeProfileID)
    }

    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        try await store.apiUpdateConversationMetadata(conversationID: conversationID, topic: topic, description: description, metadata: metadata, interactionMode: interactionMode, modeProfileID: modeProfileID)
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        try await store.apiUpdateConversationModelAndUserPrompt(conversationID: conversationID, model: model, userSystemPrompt: userSystemPrompt)
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] { try await store.apiListAvailableTools() }
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] { try await store.apiListAvailableSkills() }
    func apiListSlashCommands() async throws -> [SlashCommandAutocompleteEntry] { try await store.apiListSlashCommands() }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        try await store.apiUpdateConversationToolOverrides(conversationID: conversationID, routingPolicyTools: routingPolicyTools)
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        try await store.apiUpdateConversationSkillOverrides(conversationID: conversationID, routingPolicySkills: routingPolicySkills)
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        try await store.apiUpdateConversationThinkingConfig(conversationID: conversationID, thinkingConfig: thinkingConfig)
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws {
        try await store.apiCopyConversation(from: sourceConversationID, to: model, systemPrompt: systemPrompt)
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        try await store.apiDeleteConversation(conversationID: conversationID, hard: hard)
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        await store.apiListConversations(query: query)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        await store.apiSearchConversations(query: query)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        try await store.apiPatchConversation(conversationID: conversationID, patch: patch)
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        try await store.apiApplyConversationRESTPatch(conversationID: conversationID, patch: patch, resolvedModel: resolvedModel)
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        try await store.apiBranchConversation(conversationID: conversationID, userMessageID: userMessageID)
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        try await store.apiSpawnSubAgent(parentConversationID: parentConversationID, request: request, modelOverride: modelOverride)
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        try await store.apiInvalidateConversationCheckpoints(conversationID: conversationID, kinds: kinds)
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        await store.apiGetLatestCheckpoint(conversationID: conversationID, kind: kind)
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        await store.apiSnapshotOrchestrationState(conversationID: conversationID)
    }
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String { try await store.apiReadPlanMarkdown(conversationID: conversationID) }
    var currentConversationID: UUID? { get async { await store.currentConversationID } }
}

private final class FakeStreamingRuntimeDouble: APILayerChatRuntimeManaging, Sendable {
    private let store: FakeStreamingChatStore

    init(store: FakeStreamingChatStore) {
        self.store = store
    }

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await store.apiMessageStream(for: conversationID)
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil
    ) async throws -> ChatStreamResponse {
        try await store.apiSendMessageAndStreamResponse(
            conversationID: conversationID,
            text,
            images: images,
            enableTools: enableTools,
            enableAgents: enableAgents,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            inputTrustRaw: inputTrustRaw,
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
        try await store.apiRevertToUserMessageAndStreamResponse(
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
        try await store.apiSplitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            enableTools: enableTools,
            enableAgents: enableAgents
        )
    }

    func apiCancelMessageStream() async { await store.apiCancelMessageStream() }
    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        await store.apiSetOrchestrationStateOutOfBandPush(id: id, push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async { await store.apiClearOrchestrationStateOutOfBandPush(id: id) }
    func apiStartConversationReplay(enableTools: Bool, enableAgents: Bool) async throws { try await store.apiStartConversationReplay(enableTools: enableTools, enableAgents: enableAgents) }
    func apiStopConversationReplay() async { await store.apiStopConversationReplay() }
    func apiIsConversationReplayActive() async -> Bool { await store.apiIsConversationReplayActive() }
    func apiRequestTurnLoopStop() async { await store.apiRequestTurnLoopStop() }
    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        try await store.apiCancelRun(conversationID: conversationID, runID: runID)
    }
    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await store.apiListConversationRuns(conversationID: conversationID, filter: filter)
    }
    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        await store.apiGetConversationRun(conversationID: conversationID, runID: runID, includeProjectionDetail: includeProjectionDetail)
    }
}

private enum FakeStreamingSplitGateway {
    static func make(
        validConversationIDs: [UUID],
        initialMessages: [Message] = [],
        streamChunks: [String] = ["chunk-1", "chunk-2", "chunk-3"],
        throwOnSend: Bool = false,
        conflictOnSend: ConversationServiceError? = nil
    ) -> (conversation: FakeStreamingConversationDouble, runtime: FakeStreamingRuntimeDouble, store: FakeStreamingChatStore) {
        let store = FakeStreamingChatStore(
            validConversationIDs: validConversationIDs,
            initialMessages: initialMessages,
            streamChunks: streamChunks,
            throwOnSend: throwOnSend,
            conflictOnSend: conflictOnSend
        )
        return (
            FakeStreamingConversationDouble(store: store),
            FakeStreamingRuntimeDouble(store: store),
            store
        )
    }
}


@Suite("APILayer streaming coverage", .serialized)
struct APILayerStreamingCoverageTests {
    @Test("Split streaming gateway doubles are distinct objects sharing one store")
    func splitStreamingGatewayDoublesAreDistinct() {
        let id = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [id])
        #expect(ObjectIdentifier(conversation as AnyObject) != ObjectIdentifier(runtime as AnyObject))
    }

    @Test("REST POST /api/messages route is removed")
    func restMessagesRouteRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, store) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let modelProvider = StreamingStubModelProvider()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"hello stream","imageNames":[],"includeTools":true,"includeAgents":true}"#
            try await app.testing().test(.POST, "/api/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
        #expect(await store.lastSentText() == nil)
    }

    @Test("REST POST /api/conversations/:id/messages returns canonical append anchors")
    func restCanonicalConversationMessagesAppendAnchorsSuccess() async throws {
        let conversationID = UUID()
        let (conversation, runtime, store) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"message":"canonical stream","imageNames":[]}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-none\"")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect((json?["runId"] as? String)?.isEmpty == false)
                #expect((json?["messageId"] as? String)?.isEmpty == false)
            })
        }
        #expect(await store.lastSentText() == "canonical stream")
    }

    @Test("REST POST /api/conversations/:id/messages returns 428 when strict mode requires If-Match")
    func restCanonicalConversationMessagesStrictModeRequiresIfMatch() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"message":"strict requires match","imageNames":[]}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("REST POST /api/conversations/:id/messages returns 412 for stale If-Match")
    func restCanonicalConversationMessagesStaleIfMatchFailsPrecondition() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"message":"stale if-match","imageNames":[]}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-\(UUID().uuidString.lowercased())\"")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionFailed)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_failed")
                #expect((json?["currentVersion"] as? String)?.hasPrefix("msg-") == true)
            })
        }
    }

    @Test("REST POST /api/messages/trigger route is removed")
    func restTriggerAliasRouteRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, store) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let modelProvider = StreamingStubModelProvider()
        let api = APILayer(port: 0)
        let message = "trigger body"

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"\#(message)","triggerMetadata":{"name":"scheduler","type":"cron"}}"#
            try await app.testing().test(.POST, "/api/messages/trigger", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
        #expect(await store.lastSentText() == nil)
    }

    @Test("REST POST /api/conversations/:id/messages/trigger route is removed")
    func restTriggerConversationRouteRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, store) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let api = APILayer(port: 0)
        let message = "canonical trigger"

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"\#(message)","triggerMetadata":{"name":"canonical","type":"cron"}}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/messages/trigger", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-none\"")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
        #expect(await store.lastSentText() == nil)
    }

    @Test("REST POST /api/conversations/:id/revert streams on canonical route")
    func restCanonicalConversationRevertStreamingSuccess() async throws {
        let conversationID = UUID()
        let anchorID = UUID()
        let initialMessages = [
            Message(id: anchorID, role: .user, content: "anchor")
        ]
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(
            validConversationIDs: [conversationID],
            initialMessages: initialMessages
        )
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"userMessageID":"\#(anchorID.uuidString)","includeTools":true,"includeAgents":true}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-\(anchorID.uuidString.lowercased())\"")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let responseBody = String(data: Data(res.body.readableBytesView), encoding: .utf8) ?? ""
                #expect(responseBody.contains("chunk-1"))
                #expect(responseBody.contains("chunk-2"))
            })
        }
    }

    @Test("REST POST /api/conversations/:id/revert returns 428 without If-Match when strict mode enabled")
    func restCanonicalConversationRevertStrictModeRequiresIfMatch() async throws {
        let conversationID = UUID()
        let anchorID = UUID()
        let initialMessages = [
            Message(id: anchorID, role: .user, content: "anchor")
        ]
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(
            validConversationIDs: [conversationID],
            initialMessages: initialMessages
        )
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"userMessageID":"\#(anchorID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("REST POST /api/conversations/:id/revert returns 412 for stale If-Match")
    func restCanonicalConversationRevertStaleIfMatchFailsPrecondition() async throws {
        let conversationID = UUID()
        let anchorID = UUID()
        let initialMessages = [
            Message(id: anchorID, role: .user, content: "anchor")
        ]
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(
            validConversationIDs: [conversationID],
            initialMessages: initialMessages
        )
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"userMessageID":"\#(anchorID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-\(UUID().uuidString.lowercased())\"")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionFailed)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_failed")
            })
        }
    }

    @Test("REST POST /api/messages remains removed when stream acquisition would fail")
    func restMessagesRouteRemovedWhenRuntimeWouldFail() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID], throwOnSend: true)
        let modelProvider = StreamingStubModelProvider()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"will fail","imageNames":[]}"#
            try await app.testing().test(.POST, "/api/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("REST POST /api/messages remains removed even for conflict payloads")
    func restMessagesRouteRemovedForConflictPayload() async throws {
        let conversationID = UUID()
        let expected = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"tail conflict","imageNames":[],"expectedPreviousTailHarnessMessageID":"\#(expected.uuidString)"}"#
            try await app.testing().test(.POST, "/api/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("REST POST /api/messages/trigger remains removed for conflict payloads")
    func restTriggerAliasRemovedForConflictPayload() async throws {
        let conversationID = UUID()
        let activeRunID = UUID()
        let conflict = ConversationServiceError.conversationRunInProgress(
            conversationID: conversationID,
            activeRunID: activeRunID
        )
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(
            validConversationIDs: [conversationID],
            conflictOnSend: conflict
        )
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider())
            let body = #"{"conversationID":"\#(conversationID.uuidString)","message":"trigger conflict"}"#
            try await app.testing().test(.POST, "/api/messages/trigger", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("WS send_message returns removal error")
    func websocketSendMessageRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider()) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "send_message",
                "conversationID": conversationID.uuidString,
                "message": "hello",
                "list": []
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            #expect((response["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    @Test("WS send_trigger_message returns removal error")
    func websocketSendTriggerRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider()) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "send_trigger_message",
                "message": "trigger-ws",
                "id": conversationID.uuidString,
                "metadata": ["name": "wscron", "type": "cron"],
                "list": []
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            #expect((response["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    @Test("WS split_conversation returns removal error")
    func websocketSplitConversationRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider()) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "split_conversation",
                "conversationID": conversationID.uuidString,
                "id": UUID().uuidString,
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            #expect((response["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    @Test("WS revert_to_message returns removal error")
    func websocketRevertToMessageRemoved() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider()) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "revert_to_message",
                "conversationID": conversationID.uuidString,
                "id": UUID().uuidString,
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            #expect((response["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    @Test("WS send_message removal is deterministic even when runtime fails")
    func websocketSendMessageRemovedIndependentOfRuntime() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID], throwOnSend: true)
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: StreamingStubModelProvider()) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "send_message",
                "conversationID": conversationID.uuidString,
                "message": "hello",
                "list": []
            ])
            let error = try await receiveJSON(ofType: "error", from: task)
            #expect((error["type"] as? String == "error") || (error["kind"] as? String == "error"))
            #expect((error["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    @Test("REST smoke: running APILayer returns canonical append anchors")
    func restSmokeServerStartStop() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let modelProvider = StreamingStubModelProvider()
        let api = APILayer(port: 0)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(modelProvider)
        try await api.start()
        let port = await api.listeningPort

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/conversations/\(conversationID.uuidString)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"msg-none\"", forHTTPHeaderField: "If-Match")
        request.httpBody = Data(#"{"message":"smoke","imageNames":[]}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["runId"] as? String)?.isEmpty == false)
        #expect((json?["messageId"] as? String)?.isEmpty == false)
        await api.stop()
    }

    @Test("WebSocket smoke: removed stop_agent_build returns deterministic error")
    func websocketSmokeServerStartStop() async throws {
        let conversationID = UUID()
        let (conversation, runtime, _) = FakeStreamingSplitGateway.make(validConversationIDs: [conversationID])
        let modelProvider = StreamingStubModelProvider()
        try await withRunningAPIServer(conversation: conversation, runtime: runtime, modelProvider: modelProvider) { port in
            let task = try makeWebSocketTask(port: port)
            defer { task.cancel(with: .goingAway, reason: nil) }
            try await awaitWebSocketReady(task)
            try await sendJSON(task, [
                "type": "stop_agent_build",
                "conversationID": conversationID.uuidString
            ])
            let response = try await receiveJSON(ofType: "error", from: task)
            #expect((response["message"] as? String)?.contains("Harness control message requires kind") == true)
        }
    }

    private func withRunningAPIServer(
        conversation: APILayerConversationManaging,
        runtime: APILayerChatRuntimeManaging,
        modelProvider: APILayerModelManaging,
        _ body: (Int) async throws -> Void
    ) async throws {
        let api = APILayer(port: 0)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(modelProvider)
        try await api.start()
        let port = await api.listeningPort
        do {
            try await body(port)
            await api.stop()
        } catch {
            await api.stop()
            throw error
        }
    }

    private func makeWebSocketTask(port: Int) throws -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        return task
    }

    private func sendJSON(_ task: URLSessionWebSocketTask, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            let data = Data(text.utf8)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case .data(let data):
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        @unknown default:
            return [:]
        }
    }

    private func awaitWebSocketReady(_ task: URLSessionWebSocketTask) async throws {
        _ = task
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func receiveJSON(ofType expectedType: String, from task: URLSessionWebSocketTask, maxMessages: Int = 12) async throws -> [String: Any] {
        for _ in 0..<maxMessages {
            let payload = try await receiveJSON(task)
            if payload["type"] as? String == expectedType {
                return payload
            }
            if expectedType == "error", payload["kind"] as? String == "error" {
                return payload
            }
        }
        throw NSError(domain: "APILayerStreamingCoverageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing response type: \(expectedType)"])
    }
}
