import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum GatewaySplitNetworkTestSupport {
    static func randomPort() -> Int {
        Int.random(in: 20000...45000)
    }
}

private final class SplitGatewayStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    init(models: [Model]) { self.models = models }
    func getAvailableModels() async -> [Model] { models }
}

/// Minimal ``APILayerConversationManaging`` double for gateway wiring smoke tests.
private final class SplitConversationProtocolOnlyStub: APILayerConversationManaging, Sendable {
    func apiListConversationInfo() async -> [ModelConversation] { [] }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func apiGetConversation(id: UUID) async -> ModelConversation? { nil }
    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        _ = conversationID
        return []
    }
    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        userSystemPrompt ?? ""
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
        _ = (selectedModel, userSystemPrompt, topic, description, metadata, interactionMode, modeProfileID, cwd)
        return UUID()
    }
    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws {
        _ = (conversationID, topic, description, metadata, interactionMode, modeProfileID)
    }
    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
    }
    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        _ = conversationID
        return []
    }
    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        _ = conversationID
        return []
    }
    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        let _ = pathSegments
        return SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
    }
    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload {
        let _ = conversationID
        return TraceTopicPayload(spans: [])
    }
    func apiServerTraceSnapshot() async -> TraceTopicPayload {
        return TraceTopicPayload(spans: [])
    }
    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        let _ = limit
        return ConversationTraceResponse(conversationID: conversationID, spans: [])
    }
    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        _ = parentConversationID
        return []
    }
    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        _ = (parentConversationID, lifecycleID)
    }
    func apiPushCompletionAnnouncement(conversationID: UUID, announce: CompletionAnnouncePayload, toolMessageContent: String?) async throws {
        _ = (conversationID, announce, toolMessageContent)
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
        _ = (conversationID, runID, toolName, route, status, source, reason, durable)
    }
    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        _ = conversationID
        return []
    }
    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        _ = conversationID
        return []
    }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        _ = (conversationID, routingPolicyTools)
    }
    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        _ = (conversationID, routingPolicySkills)
    }
    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        _ = (conversationID, thinkingConfig)
    }
    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        _ = (sourceConversationID, model, systemPrompt)
        return UUID()
    }
    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        _ = (conversationID, hard)
    }
    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        _ = query
        return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }
    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        _ = query
        return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
    }
    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        _ = (conversationID, patch)
    }
    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        clientReference
    }
    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        _ = (conversationID, patch, resolvedModel)
        return 0
    }
    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        _ = (conversationID, userMessageID)
        return UUID()
    }
    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        _ = (parentConversationID, request, modelOverride)
        return UUID()
    }
    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        _ = (conversationID, kinds)
    }
    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        _ = (conversationID, kind)
        return nil
    }
    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        _ = conversationID
        return nil
    }
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        _ = conversationID
        return ""
    }
    func apiOrchestratorBoundConversationID() async -> UUID? { nil }
    func apiPreviewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String?
    ) async throws -> ContextCompactionPreviewResult {
        _ = (conversationID, gating, summarizerDebugOutputPath)
        throw APILayerChatPreviewError.notSupported
    }
    func apiPerformManualContextCompaction(conversationID: UUID, reason: String?) async throws -> ContextCompactionManualResult {
        _ = (conversationID, reason)
        throw APILayerChatPreviewError.notSupported
    }
    func apiContextCompactionManualRESTEnabled() async -> Bool { false }
    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? {
        _ = conversationID
        return nil
    }
    func apiRegistryOwnerAccountID() async -> UUID? { nil }
    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        _ = conversationID
        return nil
    }
    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = (conversationID, request)
        return []
    }
    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        _ = (key, ttlSeconds)
        return true
    }
    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }
    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data? {
        _ = (conversationID, key)
        throw APILayerConversationAPIError.unsupported
    }
    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws {
        _ = (conversationID, key, data)
        throw APILayerConversationAPIError.unsupported
    }
    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws {
        _ = (conversationID, key)
        throw APILayerConversationAPIError.unsupported
    }
}

/// Minimal ``APILayerChatRuntimeManaging`` double for gateway wiring smoke tests.
private final class SplitRuntimeProtocolOnlyStub: APILayerChatRuntimeManaging, Sendable {
    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        _ = conversationID
        return AsyncStream { $0.finish() }
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
        originSurface: String?,
        originSenderID: String?
    ) async throws -> ChatStreamResponse {
        _ = (
            conversationID,
            text,
            images,
            enableTools,
            enableAgents,
            expectedPreviousTailHarnessMessageID,
            inputTrustRaw,
            systemReminder,
            originSurface,
            originSenderID
        )
        throw APILayerConversationAPIError.unsupported
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        _ = (id, push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        _ = id
    }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        _ = (conversationID, filter)
        return ConversationRunListResponse(runs: [])
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        _ = (conversationID, runID, includeProjectionDetail)
        return nil
    }
}

/// Live-loopback ``URLSession`` checks for split gateway wiring.
/// Static `@Test` methods live on an `enum` to match ``APILayerGatewaySplitServicesTests`` (Swift 6 / existential edge case).
enum APILayerGatewaySplitServicesNetworkTests {
    @Test
    static func configureChatGatewayAcceptsIndependentProtocolOnlyInstances() async throws {
        let conversation = SplitConversationProtocolOnlyStub()
        let runtime = SplitRuntimeProtocolOnlyStub()
        #expect(ObjectIdentifier(conversation) != ObjectIdentifier(runtime))
        let port = GatewaySplitNetworkTestSupport.randomPort()
        let api = APILayer(port: port)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(SplitGatewayStubModelProvider(models: []))
        try await api.start()
        let url = URL(string: "http://127.0.0.1:\(port)/api/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["status"] as? String == "running")
        await api.stop()
    }

    @Test
    static func explicitGatewayWiringServesRESTStatus() async throws {
        let conversation = SplitConversationProtocolOnlyStub()
        let runtime = SplitRuntimeProtocolOnlyStub()
        let gateway = APILayerChatGatewayServices(conversation: conversation, runtime: runtime)
        let port = GatewaySplitNetworkTestSupport.randomPort()
        let api = APILayer(port: port)
        await api.setChatGatewayServices(gateway)
        await api.setModelProvider(SplitGatewayStubModelProvider(models: []))
        try await api.start()
        let url = URL(string: "http://127.0.0.1:\(port)/api/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = obj?["status"] as? String
        let sessions = obj?["sessions"] as? Int
        #expect(status == "running")
        #expect(sessions == 0)
        await api.stop()
    }

    @Test
    static func traceFetchRouteReturnsConversationTracePayload() async throws {
        let conversation = SplitConversationProtocolOnlyStub()
        let runtime = SplitRuntimeProtocolOnlyStub()
        let conversationID = UUID()
        let port = GatewaySplitNetworkTestSupport.randomPort()
        let api = APILayer(port: port)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(SplitGatewayStubModelProvider(models: []))
        try await api.start()

        let url = URL(string: "http://127.0.0.1:\(port)/api/traces/\(conversationID.uuidString)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((obj?["conversationID"] as? String)?.lowercased() == conversationID.uuidString.lowercased())
        let spans = obj?["spans"] as? [Any]
        #expect(spans?.isEmpty == true)
        await api.stop()
    }
}
