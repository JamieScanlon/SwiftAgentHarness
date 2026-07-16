import Foundation
import EasyJSON
import Logging
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitACP
import Synchronization
import Vapor

enum APILayerConversationAPIError: Error, Sendable {
    case unsupported
}

public struct ConversationEventsBackfillResponse: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var since: Int?
    public var latestSeq: Int
    public var lagging: Bool
    public var events: [String]
}

protocol APILayerModelManaging: AnyObject, Sendable {
    /// Wire-shaped DTO list (UI-facing). Lossy compared with the registry — see ``getRegistryEntries()``.
    func getAvailableModels() async -> [Model]
    /// Full registry rows (preserves family / providers / cost / useClasses for routing-aware callers).
    /// Default protocol impl maps from ``getAvailableModels()`` for stubs that only know about ``Model``.
    func getRegistryEntries() async -> [ModelRegistryEntry]
    /// Canonical resolve. Throws ``ModelPoolError/unavailable(reference:)`` when no entry matches.
    func resolve(_ ref: ModelReference) async throws -> ModelRegistryEntry
    /// Canonical bulk resolve. For `.id` / `.slug` returns a single-element array or throws; for `.query`
    /// returns ranked candidates (empty array when the query filters everything out — does not throw).
    func resolveAll(_ ref: ModelReference) async throws -> [ModelRegistryEntry]
}

extension APILayerModelManaging {
    func getRegistryEntries() async -> [ModelRegistryEntry] {
        await getAvailableModels().map { ModelRegistryEntry.from(model: $0, cost: $0.cost) }
    }

    func resolve(_ ref: ModelReference) async throws -> ModelRegistryEntry {
        let entries = await getRegistryEntries()
        switch ref {
        case .id(let id):
            if let hit = entries.first(where: { $0.id == id }) { return hit }
        case .slug(let slug):
            for entry in entries where entry.allSlugs.contains(slug) { return entry }
        case .query(let query):
            if let hit = ModelQuery.rank(entries: entries, query: query).first { return hit }
        }
        throw ModelPoolError.unavailable(reference: ref)
    }

    func resolveAll(_ ref: ModelReference) async throws -> [ModelRegistryEntry] {
        switch ref {
        case .id, .slug:
            return [try await resolve(ref)]
        case .query(let query):
            let entries = await getRegistryEntries()
            return ModelQuery.rank(entries: entries, query: query)
        }
    }
}

extension ModelManager: APILayerModelManaging {}

// MARK: - Chat wire protocols (Phase 4 peel seams)

/// Conversation control plane, session message reads, registry lists, orchestration snapshot reads, and context-compaction REST.
/// **Peel target:** Conversation stack (`ConversationPersistenceStack`, `ConversationManager`, …).
protocol APILayerConversationManaging: AnyObject, Sendable {
    func apiListConversationInfo() async -> [ModelConversation]
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata]
    func apiGetConversation(id: UUID) async -> ModelConversation?
    /// Control-plane read variant returning both persisted arrays (`rawEvents`, `derivedEvents`) plus current conversation snapshot.
    func apiGetConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse?
    /// On-demand projected view for transparency/debug APIs (`POST /conversations/{id}/projection`).
    func apiProjectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse
    /// Projected transcript for ``conversationID``.
    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message]
    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String
    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode, modeProfileID: String?, cwd: String?) async throws -> UUID
    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?, modeProfileID: String?) async throws
    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws
    func apiListAvailableTools() async throws -> [AvailableToolInfo]
    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo]
    /// Unified sub-agent registry rows (matches capability registry `sub-agents/registry` projection).
    func apiListSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry]
    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry]
    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload
    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload
    func apiServerTraceSnapshot() async -> TraceTopicPayload
    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse
    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo]
    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws
    func apiPushCompletionAnnouncement(
        conversationID: UUID,
        announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async throws
    func apiResolveToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool,
        arguments: JSON?
    ) async throws
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo]
    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo]
    /// Global mode profile catalog rows for picker surfaces (`GET /api/modes`).
    func apiListModeProfiles() async throws -> [ModeProfilePickerRow]
    /// Reloads mode profile config from project-local config directory when configured.
    /// Returns false when no project config directory is configured.
    func apiReloadModeProfiles() async throws -> Bool
    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry]
    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws
    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID
    /// Removes or tombstones the conversation. When `hard` is false, sets lifecycle to `.deleted` (soft delete).
    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws
    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse
    /// Harness-style message-body search across conversations (distinct from paged list metadata filter).
    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse
    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws
    /// Applies ``ModeProfileModelRouting`` for `.query` refs using the conversation row (or ``interactionMode`` when there is no row yet, e.g. create).
    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference
    /// Combined REST ``PATCH`` handler (model/prompt resolution + field patch + single control-plane revision bump).
    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64
    /// Fork at user message (control plane; does not start LLM streaming).
    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID
    /// Sub-agent spawn (fork reuses branch path; isolated creates empty child). ``modelOverride`` applies when resolving model from REST ``modelRef``.
    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID
    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws
    /// Optional harness checkpoint kind query (`context_compaction` default); see ``HarnessCheckpointWireKind``.
    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse?
    /// Latest LLM runtime + request + agentic snapshot for ``conversationID`` (REST refresh of the orchestration status strip).
    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState?
    /// Projection-policy-derived context budget for `conversation/{id}/state`.
    func apiProjectionContextBudget(conversationID: UUID) async -> ConversationContextBudget?
    /// Server-local `plan.md` markdown for the conversation (empty when no file yet).
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String

    /// Non-persisting context compaction run (harness). See `POST /api/conversations/:id/preview-context-compaction`.
    func apiPreviewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String?
    ) async throws -> ContextCompactionPreviewResult
    /// Persisting manual compaction trigger (REST surface). See `POST /api/conversations/:id/compact`.
    func apiPerformManualContextCompaction(
        conversationID: UUID,
        reason: String?
    ) async throws -> ContextCompactionManualResult
    func apiContextCompactionManualRESTEnabled() async -> Bool
    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata?
    /// When non-nil, ``conversations/registry`` payloads exclude other tenants (see ``ConversationsRegistrySnapshotBuilder``).
    func apiRegistryOwnerAccountID() async -> UUID?

    /// Store transcript head for `conversation/{id}/events` snapshot metadata (nil when unavailable).
    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int?

    /// Transcript read with spec-shaped bounds (`from`, `to`, `limit`) for replay and persistence-backed consumers.
    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry]
    /// HTTP control-plane transcript replay (`GET /conversations/{id}/events?since=`).
    func apiConversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse

    /// Harness install dedupe (`cache/dedupe.sqlite`). Missing backing store behaves as always-first-sighting.
    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool

    // MARK: - Engine artifact cache (v2 `cache/engine-artifacts`)

    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String]
    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data?
    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws
    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws
}

extension APILayerConversationManaging {
    func apiCreateConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode
    ) async throws -> UUID {
        try await apiCreateConversation(
            with: selectedModel,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: nil,
            cwd: nil
        )
    }

    func apiGetConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? {
        let _ = id
        return nil
    }

    func apiProjectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        let _ = (conversationID, request)
        throw APILayerConversationAPIError.unsupported
    }

    func apiListEngineArtifactKeys(conversationID: UUID) async throws -> [String] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetEngineArtifact(conversationID: UUID, key: String) async throws -> Data? {
        _ = conversationID
        _ = key
        throw APILayerConversationAPIError.unsupported
    }

    func apiPutEngineArtifact(conversationID: UUID, key: String, data: Data) async throws {
        _ = conversationID
        _ = key
        _ = data
        throw APILayerConversationAPIError.unsupported
    }

    func apiEvictEngineArtifacts(conversationID: UUID, key: String?) async throws {
        _ = conversationID
        _ = key
        throw APILayerConversationAPIError.unsupported
    }
}

/// Streaming turns, replay, optional background orchestration pushes, and cancellation — used by WebSocket and chunked REST streaming.
/// **Peel target:** Agent runtime + Model Pool; outbound visibility remains Communication Layer topic hubs.
public protocol APILayerChatRuntimeManaging: AnyObject, Sendable {
    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]>
    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        systemReminder: String?,
        originSurface: String?,
        originSenderID: String?
    ) async throws -> ChatStreamResponse
    func apiRevertToUserMessageAndStreamResponse(conversationID: UUID, messageID: UUID, enableTools: Bool, enableAgents: Bool) async throws -> ChatStreamResponse
    func apiSplitConversationAtUserMessage(conversationID: UUID, messageID: UUID, enableTools: Bool, enableAgents: Bool) async throws -> ChatStreamResponse
    func apiCancelMessageStream() async
    /// Publishes orchestration transitions to `conversation/{id}/state` via ``refreshConversationStateOnWire``. Registered once at composition root.
    func apiSetOrchestrationStateTopicRefreshHandler(
        _ handler: @escaping @Sendable (UUID, ConversationOrchestrationState) async -> Void
    ) async
    func apiClearOrchestrationStateTopicRefreshHandler() async
    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws
    func apiStopConversationReplay(conversationID: UUID) async
    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool
    /// User requested to stop the automatic agent build continuation loop (between `updateConversation` rounds).
    func apiRequestTurnLoopStop(conversationID: UUID) async
    /// Cancels the active streaming run when ``runID`` matches the in-flight run for ``conversationID``.
    func apiCancelRun(conversationID: UUID, runID: UUID) async throws
    /// Recent runs for a conversation (**v2 harness transcript** derivation).
    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse
    /// Lookup one run by id within transcript-derived run history.
    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo?
}

extension APILayerChatRuntimeManaging {
    /// Default: omit transcript-derived rollups (same as ``includeProjectionDetail: false``).
    func apiGetConversationRun(conversationID: UUID, runID: UUID) async -> ConversationRunInfo? {
        await apiGetConversationRun(conversationID: conversationID, runID: runID, includeProjectionDetail: false)
    }
}

/// Unified chat seam for composition roots and ``setChatProvider`` tests; REST/WebSocket use split protocols via ``APILayerRouteDependencies`` / ``APILayerWebSocketDependencies`` (Phase 5 gateway).
protocol APILayerChatManaging: APILayerConversationManaging, APILayerChatRuntimeManaging {}

enum APILayerChatPreviewError: Error {
    case notSupported
}

extension APILayerConversationManaging {
    func apiDeleteConversation(conversationID: UUID) async throws {
        try await apiDeleteConversation(conversationID: conversationID, hard: true)
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        _ = (sourceConversationID, model, systemPrompt)
        throw APILayerConversationAPIError.unsupported
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        let _ = query
        return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        let _ = query
        return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        let _ = (conversationID, patch)
        throw APILayerConversationAPIError.unsupported
    }

    func apiComposeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        let _ = (conversationID, interactionMode, clientReference)
        return clientReference
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        let _ = (conversationID, patch, resolvedModel)
        throw APILayerConversationAPIError.unsupported
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        let _ = (conversationID, userMessageID)
        throw APILayerConversationAPIError.unsupported
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        let _ = (parentConversationID, request, modelOverride)
        throw APILayerConversationAPIError.unsupported
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        let _ = (conversationID, kinds)
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        let _ = (conversationID, kind)
        return nil
    }

    func apiProjectionContextBudget(conversationID: UUID) async -> ConversationContextBudget? {
        let _ = conversationID
        return nil
    }

    func apiPreviewContextCompaction(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String? = nil
    ) async throws -> ContextCompactionPreviewResult {
        throw APILayerChatPreviewError.notSupported
    }

    func apiPerformManualContextCompaction(
        conversationID: UUID,
        reason: String? = nil
    ) async throws -> ContextCompactionManualResult {
        throw APILayerChatPreviewError.notSupported
    }

    func apiContextCompactionManualRESTEnabled() async -> Bool { false }

    func apiGetConversationServerMetadata(conversationID: UUID) async -> ConversationServerMetadata? { nil }

    func apiListMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        let _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiRegistryOwnerAccountID() async -> UUID? { nil }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        _ = conversationID
        return nil
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = request
        throw APILayerConversationAPIError.unsupported
    }

    func apiConversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        _ = conversationID
        _ = since
        throw APILayerConversationAPIError.unsupported
    }

    func apiHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        _ = key
        _ = ttlSeconds
        return true
    }

    func apiListSubAgentRegistryEntries(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiListSubAgentRegistryEntries() async throws -> [SubAgentRegistryEntry] {
        throw APILayerConversationAPIError.unsupported
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        _ = conversationID
        return nil
    }

    func apiListAvailableTools(conversationID: UUID) async throws -> [AvailableToolInfo] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] {
        throw APILayerConversationAPIError.unsupported
    }

    func apiListAvailableSkills(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] {
        throw APILayerConversationAPIError.unsupported
    }

    func apiListModeProfiles() async throws -> [ModeProfilePickerRow] {
        throw APILayerConversationAPIError.unsupported
    }

    func apiReloadModeProfiles() async throws -> Bool {
        throw APILayerConversationAPIError.unsupported
    }

    func apiListSlashCommands(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiGenerateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        _ = (conversationID, userSystemPrompt)
        throw APILayerConversationAPIError.unsupported
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
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode?,
        modeProfileID: String?
    ) async throws {
        _ = (conversationID, topic, description, metadata, interactionMode, modeProfileID)
        throw APILayerConversationAPIError.unsupported
    }

    func apiSubAgentLifecycleSnapshot(conversationID: UUID, pathSegments: [String]) async -> SubAgentLifecycleTopicPayload {
        let _ = (conversationID, pathSegments)
        return SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: [])
    }

    func apiConversationTraceSnapshot(conversationID: UUID) async -> TraceTopicPayload {
        let _ = conversationID
        return TraceTopicPayload(spans: [])
    }

    func apiServerTraceSnapshot() async -> TraceTopicPayload {
        TraceTopicPayload(spans: [])
    }

    func apiListConversationTraceSpans(conversationID: UUID, limit: Int?) async throws -> ConversationTraceResponse {
        let _ = (conversationID, limit)
        throw APILayerConversationAPIError.unsupported
    }

    func apiListActiveSubAgentInvocations(parentConversationID: UUID) async -> [ActiveSubAgentInvocationInfo] {
        let _ = parentConversationID
        return []
    }

    func apiCancelActiveSubAgentInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        let _ = (parentConversationID, lifecycleID)
        throw APILayerConversationAPIError.unsupported
    }

    func apiPushCompletionAnnouncement(
        conversationID: UUID,
        announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async throws {
        let _ = (conversationID, announce, toolMessageContent)
        throw APILayerConversationAPIError.unsupported
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
        arguments: JSON?
    ) async throws {
        let _ = (conversationID, runID, toolName, route, status, source, reason, durable, arguments)
        throw APILayerConversationAPIError.unsupported
    }
}

extension APILayerChatRuntimeManaging {
    func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        _ = (conversationID, messageID, enableTools, enableAgents)
        throw APILayerConversationAPIError.unsupported
    }

    func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        _ = (conversationID, messageID, enableTools, enableAgents)
        throw APILayerConversationAPIError.unsupported
    }

    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        _ = (conversationID, enableTools, enableAgents)
        throw APILayerConversationAPIError.unsupported
    }

    func apiStopConversationReplay(conversationID: UUID) async {
        _ = conversationID
    }

    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool {
        _ = conversationID
        return false
    }

    func apiRequestTurnLoopStop(conversationID: UUID) async {
        _ = conversationID
    }
}

/**
 * APILayer manages all network communication from the Client to the Server.
 *
 * This class is responsible for setting up and managing the HTTP server that handles
 * both REST API calls and WebSocket connections.
 *
 * ## Swift concurrency
 * Route bodies are ``Sendable``; Vapor may invoke them concurrently. ``APILayer`` must not
 * be captured in those closures. WebSocket setup snapshots ``ModelStateTopicHub``, optional ``ConversationTopicPublishing``,
 * and ``ModelInvocationCoordinator`` when ``start()`` registers routes (configure dependencies before then).
 * Handlers use only those references plus ``APILayerWebSocketDependencies``.
 *
 * ``conversationStateTopicHub`` / ``conversationStatePublisher`` feed ``conversation/{id}/state`` (see ``ConversationStatePublishing``).
 * ``capabilityRegistryTopicHub`` / ``capabilityRegistryPublisher`` feed ``tools/registry``, ``skills/registry``, and ``sub-agents/registry`` (see ``CapabilityRegistryPublishing``).
 * ``conversationsRegistryTopicHub`` / ``conversationsRegistryPublisher`` feed ``conversations/registry`` (account/session catalog changes).
 */
public actor APILayer {
    private struct APIRouteDiagnosticsMiddleware: AsyncMiddleware {
        let logger: Logger

        private func canonicalizedPath(_ path: String) -> String {
            let collapsed = path.replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
            if collapsed.count > 1, collapsed.hasSuffix("/") {
                return String(collapsed.dropLast())
            }
            return collapsed
        }

        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            let response = try await next.respond(to: request)
            if request.url.path.hasPrefix("/api") {
                let requestID = request.headers.first(name: "request-id")
                    ?? request.headers.first(name: "x-request-id")
                    ?? request.logger[metadataKey: "request-id"]?.description
                    ?? "unknown"
                let path = canonicalizedPath(request.url.path)
                logger.warning(
                    "APIRouteDiagnostics observed response status=\(response.status.code). method=\(request.method.rawValue) path=\(request.url.path) canonicalPath=\(path) query=\(request.url.query ?? "") request-id=\(requestID)"
                )
                if path == "/api/conversations", response.status == .notFound {
                    logger.error(
                        "Canonical conversations list route returned 404. method=\(request.method.rawValue) path=\(request.url.path) canonicalPath=\(path) query=\(request.url.query ?? "") request-id=\(requestID)"
                    )
                } else if path == "/api/conversations" {
                    logger.warning(
                        "Canonical conversations list route response status=\(response.status.code). method=\(request.method.rawValue) path=\(request.url.path) canonicalPath=\(path) query=\(request.url.query ?? "") request-id=\(requestID)"
                    )
                }
            }
            return response
        }
    }
    
    /**
     * Initializes a new APILayer instance.
     *
     * - Parameter port: The port number that the server will listen on.
     */
    public init(
        port: Int,
        logger: Logger = SwiftAgentKitLogging.logger(for: .custom(subsystem: "APILayer")),
        serverTraceSubscribePolicy: ServerTraceSubscribePolicy = .open
    ) {
        self.port = port
        self.logger = logger
        self.serverTraceSubscribePolicy = serverTraceSubscribePolicy
    }
    
    /// Internal test seam to inject a chat provider without constructing HarnessRuntimeSession.
    func setChatProvider(_ provider: APILayerChatManaging) {
        self.chatGateway = APILayerChatGatewayServices(unified: provider)
    }

    /// Test / advanced wiring: inject split conversation vs runtime instances explicitly.
    public func setChatGatewayServices(_ gateway: APILayerChatGatewayServices) {
        self.chatGateway = gateway
    }
    
    /**
     * Sets the model available for this API layer.
     *
     * - Parameter modelManager: The model manager instance to use.
     */
    public func setModelManager(_ modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Internal test seam to inject a model provider without constructing ModelManager.
    func setModelProvider(_ provider: APILayerModelManaging) {
        self.modelManager = provider
    }
    
    public func setOAuthCallbackDelivery(_ delivery: OAuthCallbackDelivery) {
        self.oauthCallbackDelivery = delivery
    }

    public func setTriggerWebhookRegistrar(_ registrar: TriggerWebhookRouteRegistrar?) {
        self.triggerWebhookRegistrar = registrar
    }

    private var startupService: ConversationStartupService?

    /// Binds the harness startup service for composition-root wiring (``setMCPManager(_:)``, etc.).
    public func setStartupService(_ startup: ConversationStartupService) {
        startupService = startup
    }

    public func setMCPManager(
        _ mcpManager: MCPManager,
        visibilityGrant: ToolVisibilityGrant = .grant(modes: .allUserFacing)
    ) async {
        guard let startupService else { return }
        await startupService.setMCPManager(mcpManager, visibilityGrant: visibilityGrant)
    }

    public func setACPManager(_ acpManager: ACPManager, delegateBoxes: [String: SubAgentACPClientDelegateBox]) async {
        guard let startupService else { return }
        await startupService.setACPManager(acpManager, delegateBoxes: delegateBoxes)
    }

    public func setContextCompactionPreviewSettings(_ settings: ContextCompactionPreviewAPISettings) {
        self.contextCompactionPreviewSettings = settings
    }

    public func setHTTPPreconditionPolicySettings(_ settings: HTTPPreconditionPolicySettings) {
        self.httpPreconditionPolicySettings = settings
    }

    public func setTenancyPolicySettings(_ settings: TenancyPolicySettings) {
        self.tenancyPolicySettings = settings
    }

    /// Configures HS256 JWT validation for ``Authorization: Bearer`` authenticated tenancy.
    public func setAPIAccessTokenAuthenticationSettings(_ settings: APIAccessTokenAuthenticationSettings?) {
        if let settings {
            apiAccessTokenValidator = JWTAPIAccessTokenValidator(settings: settings)
        } else {
            apiAccessTokenValidator = nil
        }
    }

    /// Wires tenancy, trace subscribe policy, and access-token auth from ``ServerConfig``.
    public func applyServerConfig(_ config: ServerConfig) {
        tenancyPolicySettings = config.tenancyPolicySettings()
        serverTraceSubscribePolicy = config.resolvedServerTraceSubscribePolicy()
        apiAccessTokenValidator = config.makeAPIAccessTokenValidator()
        engineArtifactMaxUploadBytes = config.engineArtifactMaxUploadBytes
        websocketOutboundFlowConfiguration = config.websocketOutboundFlowConfiguration
        websocketOutboundSchemaEnforcementConfiguration = config.websocketOutboundSchemaEnforcementConfiguration
        websocketResumeTokenHMACSecret = config.websocketResumeTokenHMACSecret
        websocketInboundDedupeDefaultTtlSeconds = config.websocketInboundDedupeDefaultTtlSeconds
        websocketInboundDedupeMaxTtlSeconds = config.websocketInboundDedupeMaxTtlSeconds
        httpPreconditionPolicySettings = HTTPPreconditionPolicySettings(
            strictMode: config.httpPreconditionsStrictMode
        )
    }

    public func setEngineArtifactRESTSettings(maxUploadBytes: Int) {
        self.engineArtifactMaxUploadBytes = max(1024, maxUploadBytes)
    }

    public func setWebSocketOutboundFlowConfiguration(_ configuration: WebSocketOutboundFlowConfiguration) {
        websocketOutboundFlowConfiguration = configuration
    }

    public func setWebSocketOutboundSchemaEnforcementConfiguration(_ configuration: WebSocketOutboundSchemaEnforcementConfiguration) {
        websocketOutboundSchemaEnforcementConfiguration = configuration
    }

    /// HMAC secret for `conversation/{id}/events` resume tokens (`SAH_WS_RESUME_TOKEN_SECRET`-style). When nil or empty, resume tokens are rejected.
    public func setWebSocketResumeTokenHMACSecret(_ secret: String?) {
        websocketResumeTokenHMACSecret = secret
    }

    /// Default and cap (seconds) for inbound ``CommClientMessage/dedupeCheckAndSet`` TTL when clients omit `dedupeTtlSeconds`.
    public func setWebSocketInboundDedupeTtlPolicy(defaultSeconds: Int, maxSeconds: Int) {
        websocketInboundDedupeDefaultTtlSeconds = max(60, defaultSeconds)
        websocketInboundDedupeMaxTtlSeconds = max(websocketInboundDedupeDefaultTtlSeconds, maxSeconds)
    }

    /// Wires the model pool state topic hub and coordinator for WebSocket `model/{id}/state` subscriptions.
    public func setModelStateWireResources(hub: ModelStateTopicHub, coordinator: ModelInvocationCoordinator) {
        self.modelStateTopicHub = hub
        self.modelInvocationCoordinator = coordinator
    }

    /// Wires the conversation events topic hub for WebSocket `conversation/{id}/events` subscriptions.
    ///
    /// - Parameter replayRetention: Optional transcript replay-window override. When `nil` (default)
    ///   the subscribe path resolves the window from the environment
    ///   (`SAH_TRANSCRIPT_TAIL_MAX_SEQUENCE_LAG`); supply a value to make the policy deterministic
    ///   without mutating process-global state.
    public func setConversationEventsWireResources(
        hub: ConversationEventsTopicHub,
        replayRetention: TranscriptTailRetentionPolicy? = nil
    ) {
        self.conversationEventsTopicHub = hub
        self.conversationEventsReplayRetention = replayRetention
    }

    /// Production wiring: one ``CommunicationLayer`` plus coordinator (same hubs as the aggregate).
    public func setCommunicationWireResources(layer: CommunicationLayer, coordinator: ModelInvocationCoordinator) {
        self.modelStateTopicHub = layer.modelPoolTopics
        self.conversationEventsTopicHub = layer.conversationEvents
        self.conversationStateTopicHub = layer.conversationState
        self.traceTopicHub = layer.traceTopics
        self.subAgentLifecycleTopicHub = layer.subAgentLifecycle
        self.capabilityRegistryTopicHub = layer.capabilityRegistries
        self.conversationsRegistryTopicHub = layer.conversationsRegistry
        self.modelInvocationCoordinator = coordinator
        conversationStatePublisher = layer
        capabilityRegistryPublisher = layer
        conversationsRegistryPublisher = layer
    }

    /// Injects the budget reporting seam used to enrich `conversation/{id}/state.projectedCostUSD`.
    /// Defaults to ``NilBudgetReporting`` for tests; production wiring injects
    /// the real ledger-backed reporter.
    public func setBudgetReporting(_ reporter: any BudgetReporting) {
        self.budgetReporting = reporter
    }

    /// Test wiring when only ``ConversationStateTopicHub`` is injected (no full communication aggregate).
    public func setConversationStateWireResources(hub: ConversationStateTopicHub) {
        self.conversationStateTopicHub = hub
        conversationStatePublisher = ConversationStateHubOnlyPublisher(hub: hub)
    }

    /// Refreshes ``conversation/{id}/state`` when REST or streaming paths change session or metadata (subscribe-gated).
    public func refreshConversationStateOnWire(
        conversationID: UUID,
        orchestrationOverride: ConversationOrchestrationState? = nil
    ) async {
        guard let gateway = chatGateway,
              let publisher = conversationStatePublisher else { return }
        logger.debug("refreshConversationStateOnWire start conversationID=\(conversationID.uuidString)")
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: conversationID,
            conversation: gateway.conversation,
            runtime: gateway.runtime,
            poolStateProvider: makePoolStateProvider(),
            activeCallProvider: makeActiveCallProvider(),
            projectedCostProvider: makeProjectedCostProvider(),
            projectionBudgetProvider: makeProjectionBudgetProvider(),
            orchestrationOverride: orchestrationOverride
        )
        logger.debug(
            "refreshConversationStateOnWire payload conversationID=\(conversationID.uuidString) llm=\(payload.orchestration?.llmRuntimePhase.rawValue ?? "nil") request=\(payload.orchestration?.llmRequestPhase?.rawValue ?? "nil") agentic=\(payload.orchestration?.agenticPhase.rawValue ?? "nil") runID=\(payload.orchestration?.currentRunID?.uuidString ?? "nil")"
        )
        await publisher.publishConversationState(conversationID: conversationID, payload: payload)
        //logger.debug("refreshConversationStateOnWire published conversationID=\(conversationID.uuidString)")
    }

    /// Builds a closure that resolves ``ModelStatePayload`` for a model from the wire-bound
    /// ``ModelInvocationCoordinator``. Returns `nil` (the closure itself) when no coordinator is wired.
    /// The closure returns `nil` for models the coordinator has never observed, so the snapshot doesn't
    /// carry a synthetic ``.done`` payload.
    func makePoolStateProvider() -> ConversationStateSnapshotBuilder.PoolStateProvider? {
        guard let coordinator = modelInvocationCoordinator else { return nil }
        return { modelID in
            guard await coordinator.latestPhase(for: modelID) != nil else { return nil }
            return await coordinator.snapshot(for: modelID)
        }
    }

    /// Builds a closure resolving the currently dispatched `(modelID, callID)` for a conversation
    /// via the coordinator's reverse lookup. `nil` when no coordinator is wired.
    func makeActiveCallProvider() -> ConversationStateSnapshotBuilder.ActiveCallProvider? {
        guard let coordinator = modelInvocationCoordinator else { return nil }
        return { conversationID in
            await coordinator.activeCall(forConversationID: conversationID)
        }
    }

    /// Builds a closure resolving projected USD spend for a conversation via ``BudgetReporting``.
    /// Always returns a closure (the underlying default ``NilBudgetReporting`` returns `nil`).
    func makeProjectedCostProvider() -> ConversationStateSnapshotBuilder.ProjectedCostProvider? {
        let reporter = budgetReporting
        return { conversationID in
            await reporter.projectedCostUSD(conversationID: conversationID)
        }
    }

    /// Builds a closure resolving projection-policy-derived context budget for a conversation.
    func makeProjectionBudgetProvider() -> ConversationStateSnapshotBuilder.ProjectionBudgetProvider? {
        guard let gateway = chatGateway else { return nil }
        return { conversationID in
            await gateway.conversation.apiProjectionContextBudget(conversationID: conversationID)
        }
    }

    /// Refreshes ``tools/registry``, ``skills/registry``, and ``sub-agents/registry`` for ``conversationID`` (subscribe-gated).
    func refreshCapabilityRegistriesOnWire(for conversationID: UUID) async {
        guard let gateway = chatGateway,
              let publisher = capabilityRegistryPublisher else { return }
        let conv = gateway.conversation
        let tools = await CapabilityRegistrySnapshotBuilder.buildTools(conversation: conv, conversationID: conversationID)
        let skills = await CapabilityRegistrySnapshotBuilder.buildSkills(conversation: conv, conversationID: conversationID)
        let agents = await CapabilityRegistrySnapshotBuilder.buildSubAgents(conversation: conv, conversationID: conversationID)
        await publisher.publishToolsRegistry(tools)
        await publisher.publishSkillsRegistry(skills)
        await publisher.publishSubAgentsRegistry(agents)
    }

    /// Publishes account/session catalog deltas on `conversations/registry` (subscribe-gated).
    func refreshConversationsRegistryOnWire(
        kind: ConversationRegistryChange.Kind,
        conversationID: UUID
    ) async {
        guard let gateway = chatGateway,
              let publisher = conversationsRegistryPublisher else { return }
        if let scope = await gateway.conversation.apiRegistryOwnerAccountID(),
           let conv = await gateway.conversation.apiGetConversation(id: conversationID),
           conv.ownerAccountID != scope {
            return
        }
        let payload = await ConversationsRegistrySnapshotBuilder.event(
            kind: kind,
            conversationID: conversationID,
            conversation: gateway.conversation
        )
        await publisher.publishConversationsRegistry(payload)
    }

    /// Broadcasts a server-scoped mode registry invalidation marker (`mode_registry_changed`) when subscribers exist.
    public func publishModeRegistryChangedOnWire() async {
        guard let traceTopicHub else { return }
        guard await traceTopicHub.hasSubscribers(forTopic: TraceTopicFormat.serverTopic) else { return }
        let payload = TraceTopicPayload(
            spans: [
                TraceSpanPayload(
                    traceID: UUID(),
                    name: "mode_registry_changed",
                    category: "registry",
                    source: "modeRegistry"
                ),
            ]
        )
        await traceTopicHub.broadcastServer(payload: payload)
    }
    
    /**
     * Starts the API server.
     * This is a BLOCKING Call. 
     *
     * This method initializes the Vapor application, sets up routes for REST API and
     * WebSockets, and begins listening for connections on the configured port.
     *
     * - Throws: APIError if the server components aren't properly initialized
     *           or if the server fails to start.
     */
    /// Validates wiring required before ``start()`` without binding a listen socket.
    func validateStartupPreconditions() throws {
        guard chatGateway != nil, modelManager != nil else {
            throw APIError.componentsNotInitialized
        }
        if tenancyPolicySettings.requireAuthenticatedOwnerOnMutations,
           apiAccessTokenValidator == nil {
            throw APIError.authenticationNotConfigured
        }
    }

    public func start() async throws {
        try validateStartupPreconditions()
        guard let chatGateway = chatGateway, let modelManager = modelManager else {
            throw APIError.componentsNotInitialized
        }

        var env = Environment.production
        env.arguments = ["SwiftAgentHarness"]
        let app = try await Application.make(env)
        self.app = app

        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "0.0.0.0"

        try configureServingApplication(app: app, chatGateway: chatGateway, modelManager: modelManager)

        try await app.startup()
    }

    /// Registers REST + WebSocket routes on a Vapor application without binding a listen socket.
    public func makeEmbeddedApplication() async throws -> Application {
        try validateStartupPreconditions()
        guard let chatGateway = chatGateway, let modelManager = modelManager else {
            throw APIError.componentsNotInitialized
        }
        var env = Environment.testing
        env.arguments = ["SwiftAgentHarness"]
        let app = try await Application.make(env)
        app.http.server.configuration.port = 0
        app.http.server.configuration.hostname = "127.0.0.1"
        try configureServingApplication(app: app, chatGateway: chatGateway, modelManager: modelManager)
        try await app.startup()
        return app
    }

    /// In-process REST loopback client over ``makeEmbeddedApplication()``.
    public func makeEmbeddedAPIClient() async throws -> EmbeddedHarnessAPIClient {
        let app = try await makeEmbeddedApplication()
        return EmbeddedHarnessAPIClient(app: app)
    }

    private func configureServingApplication(
        app: Application,
        chatGateway: APILayerChatGatewayServices,
        modelManager: APILayerModelManaging
    ) throws {
        app.routes.defaultMaxBodySize = "100mb"
        app.middleware.use(APIRouteDiagnosticsMiddleware(logger: logger))
        logger.warning("APIRouteDiagnosticsMiddleware installed (v2)")
        Task { [weak self] in
            await chatGateway.runtime.apiSetOrchestrationStateTopicRefreshHandler { [weak self] conversationID, state in
                await self?.refreshConversationStateOnWire(
                    conversationID: conversationID,
                    orchestrationOverride: state
                )
            }
        }
        configureRESTRoutes(app: app, chatGateway: chatGateway, modelManager: modelManager)
        configureWebSocketRoutes(app: app, chatGateway: chatGateway, modelManager: modelManager)
    }

    /// Bound listen port after ``start()``; when initialized with `0`, returns the OS-assigned ephemeral port.
    public var listeningPort: Int {
        guard let app else { return port }
        if let bound = app.http.server.shared.localAddress?.port {
            return Int(bound)
        }
        return port
    }
    
    /**
     * Gracefully shuts down the API server.
     *
     * This method stops the Vapor application and releases all resources.
     */
    public func stop() async {
        logger.info("Shutting down API server...")
        if let running = app?.running {
            running.stop()
            _ = try? await running.onStop.get()
        }
        app = nil
        logger.info("API server shutdown complete")
    }
    
    
    
    // MARK: - Private
    
    /// The port that the API server listens on
    private let port: Int
    
    /// The Vapor application instance
    private var app: Application?
    // Note: We avoid using Application.execute/ServeCommand to prevent assertion on deinit.
    
    /// Split gateway (conversation vs runtime); production uses distinct ``ConversationSessionService`` / ``ChatRuntimeService`` instances over one ``HarnessRuntimeSession``.
    private var chatGateway: APILayerChatGatewayServices?
    
    /// Reference to the model manager for getting available models
    private var modelManager: APILayerModelManaging?

    /// Reference to the OAuth callback delivery for handling OAuth redirects
    private var oauthCallbackDelivery: OAuthCallbackDelivery?

    private var triggerWebhookRegistrar: TriggerWebhookRouteRegistrar?

    private var contextCompactionPreviewSettings: ContextCompactionPreviewAPISettings = .disabled
    private var httpPreconditionPolicySettings: HTTPPreconditionPolicySettings = .disabled
    private var tenancyPolicySettings: TenancyPolicySettings = .disabled
    private var engineArtifactMaxUploadBytes: Int = 16_777_216

    /// When set, enables `kind: subscribe` / `unsubscribe` for `model/{id}/state` on `/ws`.
    private var modelStateTopicHub: ModelStateTopicHub?
    private var modelInvocationCoordinator: ModelInvocationCoordinator?

    /// When set, enables `kind: subscribe` / `unsubscribe` for `conversation/{id}/events` on `/ws`.
    private var conversationEventsTopicHub: ConversationEventsTopicHub?

    /// Optional deterministic transcript replay-window override for `conversation/{id}/events`
    /// subscribes. `nil` falls back to the environment-derived policy at request time.
    private var conversationEventsReplayRetention: TranscriptTailRetentionPolicy?

    /// When set, enables `kind: subscribe` / `unsubscribe` for `conversation/{id}/state` on `/ws`.
    private var conversationStateTopicHub: ConversationStateTopicHub?

    /// When set, enables `trace/{conversationId}` and `trace/server` subscriptions on `/ws`.
    private var traceTopicHub: TraceTopicHub?

    /// Outbound fan-out for `conversation/{id}/state`.
    private var conversationStatePublisher: (any ConversationStatePublishing)?

    /// When set, enables `tools/registry`, `skills/registry`, `sub-agents/registry` subscriptions on `/ws`.
    private var capabilityRegistryTopicHub: CapabilityRegistryTopicHub?
    /// When set, enables `conversations/registry` subscriptions on `/ws`.
    private var conversationsRegistryTopicHub: ConversationsRegistryTopicHub?

    /// When set, enables `subagent/{conversationId}/{path}/{events|state}` subscriptions on `/ws`.
    private var subAgentLifecycleTopicHub: SubAgentLifecycleTopicHub?

    private var websocketOutboundFlowConfiguration: WebSocketOutboundFlowConfiguration = .init()
    private var websocketOutboundSchemaEnforcementConfiguration: WebSocketOutboundSchemaEnforcementConfiguration = .default
    private var serverTraceSubscribePolicy: ServerTraceSubscribePolicy
    private var websocketResumeTokenHMACSecret: String?
    private var websocketInboundDedupeDefaultTtlSeconds: Int = 600
    private var websocketInboundDedupeMaxTtlSeconds: Int = 3600
    private var apiAccessTokenValidator: (any APIAccessTokenValidating)?

    /// Outbound fan-out for session capability registry topics (``CommunicationLayer`` or hub-only adapter in tests).
    private var capabilityRegistryPublisher: (any CapabilityRegistryPublishing)?
    /// Outbound fan-out for account/session conversation catalog topic.
    private var conversationsRegistryPublisher: (any ConversationsRegistryPublishing)?

    /// Read-only seam used to populate ``ConversationStatePayload/projectedCostUSD``. Defaults to
    /// ``NilBudgetReporting`` (returns `nil`) for tests; production replaces this via
    /// ``setBudgetReporting(_:)`` during server composition.
    private var budgetReporting: any BudgetReporting = NilBudgetReporting()

    private let logger: Logger
    
    /**
     * Configures REST API routes for the Vapor application.
     *
     * - Parameters:
     *   - app: The Vapor application.
     *   - chatGateway: Conversation + runtime services (typically split wrappers over one ``HarnessRuntimeSession``).
     */
    private func configureRESTRoutes(app: Application, chatGateway: APILayerChatGatewayServices, modelManager: APILayerModelManaging) {
        
        app.get { req async in
            "It works!"
        }
        
        // OAuth callback: receive redirect from provider, deliver to SwiftAgentKit manual flow, return HTML
        Self.registerOAuthCallbackRoute(on: app, delivery: oauthCallbackDelivery, logger: logger)
        triggerWebhookRegistrar?.register(on: app)
        
        // API route group (per-client selection scope via ``ClientSessionMiddleware``).
        let api = app.grouped("api").grouped(ClientSessionMiddleware(
            logger: logger,
            accessTokenValidator: apiAccessTokenValidator
        ))
        let dependencies = APILayerRouteDependencies(
            gateway: chatGateway,
            modelManager: modelManager,
            logger: logger,
            oauthCallbackDelivery: oauthCallbackDelivery,
            contextCompactionPreview: contextCompactionPreviewSettings,
            httpPreconditions: httpPreconditionPolicySettings,
            tenancyPolicy: tenancyPolicySettings,
            modelStateTopicHub: modelStateTopicHub,
            modelInvocationCoordinator: modelInvocationCoordinator,
            engineArtifactMaxBodyBytes: engineArtifactMaxUploadBytes,
            onConversationStateChanged: { [weak self] id in
                await self?.refreshConversationStateOnWire(conversationID: id)
                await self?.refreshCapabilityRegistriesOnWire(for: id)
            },
            onConversationsRegistryChanged: { [weak self] kind, id in
                await self?.refreshConversationsRegistryOnWire(kind: kind, conversationID: id)
            }
        )
        logger.info("Registering canonical route GET /api/conversations (paged list)")
        api.get("conversations") { req async throws -> Response in
            try await APILayerConversationsModule.conversationListHTTPResponse(req: req, dependencies: dependencies)
        }
        APILayerRESTModuleRegistry(modules: APILayerModuleAssembly.restModules())
            .registerAll(on: api, dependencies: dependencies)
    }
    
    /**
     * Configures WebSocket routes for the Vapor application.
     *
     * - Parameters:
     *   - app: The Vapor application.
     *   - chatGateway: Conversation + runtime services for WS handlers.
     *   - modelManager:The model manager.
     */
    private func configureWebSocketRoutes(app: Application, chatGateway: APILayerChatGatewayServices, modelManager: APILayerModelManaging) {
        // Snapshot for @Sendable WebSocket handlers (config is finalized before `start()` registers routes).
        let wireLogger = logger
        let wireModelStateHub = modelStateTopicHub
        let wireConversationEventsHub = conversationEventsTopicHub
        let wireConversationEventsReplayRetention = conversationEventsReplayRetention
        let wireConversationStateHub = conversationStateTopicHub
        let wireTraceHub = traceTopicHub
        let wireCapabilityRegistryHub = capabilityRegistryTopicHub
        let wireConversationsRegistryHub = conversationsRegistryTopicHub
        let wireSubAgentLifecycleHub = subAgentLifecycleTopicHub
        let wireOutboundFlowConfiguration = websocketOutboundFlowConfiguration
        let wireServerTraceSubscribePolicy = serverTraceSubscribePolicy
        let wireOutboundSchemaEnforcementConfiguration = websocketOutboundSchemaEnforcementConfiguration
        let wireResumeTokenSecret = websocketResumeTokenHMACSecret
        let wireInboundDedupeDefaultTtl = websocketInboundDedupeDefaultTtlSeconds
        let wireInboundDedupeMaxTtl = websocketInboundDedupeMaxTtlSeconds
        let wireAccessTokenValidator = apiAccessTokenValidator
        let wireModelInvocationCoordinator = modelInvocationCoordinator
        let wireModelManager = modelManager
        let wireConversation = chatGateway.conversation
        let wireRuntime = chatGateway.runtime
        let wireBudgetReporting: any BudgetReporting = budgetReporting
        let wireTenancyPolicy = tenancyPolicySettings
        
        // WebSocket route for chat
        app.webSocket("ws", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: Int(UInt32.max))) { req, ws in
            
            let logger = wireLogger
            let wsRequestID: String = req.headers.first(name: "request-id")
                ?? req.headers.first(name: "x-request-id")
                ?? req.logger[metadataKey: "request-id"]?.description
                ?? "unknown"
            let wsAuthenticatedOwner: UUID? = APISessionAuthenticatedOwnerResolver.resolve(
                from: req.headers,
                validator: wireAccessTokenValidator
            )
            if wireTenancyPolicy.requireAuthenticatedOwnerOnMutations, wsAuthenticatedOwner == nil {
                logger.warning(
                    "WS upgrade rejected requestID=\(wsRequestID): authenticated owner required (valid Authorization Bearer token on WebSocket handshake)"
                )
                Task {
                    try? await ws.close(code: .policyViolation)
                }
                return
            }
            let topicRegistration = WebSocketTopicWireRegistration()
            let outboundSchemaViolationTracker = WebSocketOutboundSchemaViolationTracker(
                configuration: wireOutboundSchemaEnforcementConfiguration
            )
            let sendControlPayload: @Sendable ([String: Any]) async -> Void = { payload in
                if wireOutboundSchemaEnforcementConfiguration.enabled,
                   let issue = WebSocketOutboundHarnessValidation.validationIssueForControlResponsePayload(payload) {
                    logger.warning("WS outbound control schema violation: \(issue.detail)")
                    do {
                        try await ws.send(APILayer.harnessErrorPayload(
                            message: "Outbound schema violation",
                            code: "outbound_schema_violation"
                        ))
                    } catch {
                        logger.warning("WS send control error failed: \(error)")
                    }
                    let disconnect = await outboundSchemaViolationTracker.recordViolation()
                    if disconnect {
                        logger.warning("WS outbound control schema violation threshold reached; closing websocket")
                        try? await ws.close()
                    }
                    return
                }
                do {
                    try await ws.send(payload)
                } catch {
                    logger.warning("WS send control payload failed: \(error)")
                }
            }
            let summarizeHarnessLine: @Sendable (HarnessOutboundWireLine) -> String = { line in
                "kind=\(line.kind.rawValue) topic=\(line.topic) seq=\(line.seq) bytes=\(line.json.utf8.count)"
            }
            let outboundLimiter = WebSocketHarnessOutboundFlowLimiter(
                configuration: wireOutboundFlowConfiguration,
                wsSend: { [weak ws] json in
                    guard let ws else { return }
                    logger.debug("WS outbound harness \(json)")
                    try await ws.send(json)
                },
                requestDisconnect: { [weak ws] in
                    guard let ws else { return }
                    _ = ws.close()
                }
            )
            topicRegistration.outboundFlowLimiter = outboundLimiter
            let topicHubForRegistration = wireModelStateHub
            Task {
                if let hub = topicHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.modelTopicHubToken = token
                }
            }
            let conversationHubForRegistration = wireConversationEventsHub
            Task {
                if let hub = conversationHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.conversationEventsTopicHubToken = token
                }
            }
            let conversationStateHubForRegistration = wireConversationStateHub
            Task {
                if let hub = conversationStateHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.conversationStateTopicHubToken = token
                }
            }
            let subAgentLifecycleHubForRegistration = wireSubAgentLifecycleHub
            Task {
                if let hub = subAgentLifecycleHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.subAgentLifecycleTopicHubToken = token
                }
            }
            let traceHubForRegistration = wireTraceHub
            Task {
                if let hub = traceHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.traceTopicHubToken = token
                }
            }
            let capabilityRegistryHubForRegistration = wireCapabilityRegistryHub
            Task {
                if let hub = capabilityRegistryHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.capabilityRegistryTopicHubToken = token
                }
            }
            let conversationsRegistryHubForRegistration = wireConversationsRegistryHub
            Task {
                if let hub = conversationsRegistryHubForRegistration {
                    let token = await hub.registerConnection { line in
                        logger.debug("WS outbound harness \(summarizeHarnessLine(line))")
                        try await outboundLimiter.sendHarnessLine(line)
                    }
                    topicRegistration.conversationsRegistryTopicHubToken = token
                }
            }
            // Stable scope for this socket's ledger row (mirrors REST X-SAH-Client-Session / cookie semantics).
            let connectionNamespace = UUID()
            
            // Handle incoming WebSocket messages
            ws.onText { ws, text in
                guard let data = text.data(using: .utf8) else {
                    Task {
                        await sendControlPayload(APILayer.harnessErrorPayload(message: "Invalid message encoding"))
                    }
                    return
                }

                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    logger.error("Invalid JSON message")
                    Task {
                        await sendControlPayload(APILayer.harnessErrorPayload(message: "Invalid JSON message"))
                    }
                    return
                }
                if let schemaErr = WebSocketCommClientControlValidator.validationError(jsonObject: obj) {
                    Task {
                        await sendControlPayload(APILayer.harnessErrorPayload(message: schemaErr))
                    }
                    return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let comm = try? decoder.decode(CommClientControlMessage.self, from: data) else {
                    Task {
                        await sendControlPayload(APILayer.harnessErrorPayload(message: "Invalid harness control message"))
                    }
                    return
                }
                logger.info(
                    "WS control message requestID=\(wsRequestID) kind=\(comm.kind.rawValue) topic=\(comm.topic ?? "none") owner=\(wsAuthenticatedOwner?.uuidString ?? "none") namespace=\(connectionNamespace.uuidString)"
                )
                Task {
                    await APISessionContext.$connectionNamespace.withValue(connectionNamespace) {
                        await APISessionContext.$authenticatedOwnerAccountID.withValue(wsAuthenticatedOwner) {
                        if let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                            modelHub: wireModelStateHub,
                            conversationHub: wireConversationEventsHub,
                            conversationStateHub: wireConversationStateHub,
                            traceHub: wireTraceHub,
                            subAgentLifecycleHub: wireSubAgentLifecycleHub,
                            capabilityRegistryHub: wireCapabilityRegistryHub,
                            conversationsRegistryHub: wireConversationsRegistryHub,
                            coordinator: wireModelInvocationCoordinator,
                            conversationSession: wireConversation,
                            chatRuntime: wireRuntime,
                            budgetReporting: wireBudgetReporting,
                            modelManager: wireModelManager,
                            resumeTokenHMACSecret: wireResumeTokenSecret,
                            inboundDedupeDefaultTtlSeconds: wireInboundDedupeDefaultTtl,
                            inboundDedupeMaxTtlSeconds: wireInboundDedupeMaxTtl,
                            inboundDedupePerform: { key, ttl in
                                try await wireConversation.apiHarnessDedupeCheckAndSet(key: key, ttlSeconds: ttl)
                            },
                            inboundDedupeRespond: { first in
                                await sendControlPayload(APILayer.harnessDedupeResultPayload(firstSighting: first))
                            },
                            serverTraceSubscribePolicy: wireServerTraceSubscribePolicy,
                            conversationEventsReplayRetention: wireConversationEventsReplayRetention ?? .fromEnvironmentOrDefault(),
                            tenancyPolicy: wireTenancyPolicy,
                            message: comm,
                            registration: topicRegistration
                        ) {
                            if err == "Subscribe denied" {
                                logger.warning(
                                    "WS subscribe denied requestID=\(wsRequestID) topic=\(comm.topic ?? "unknown") owner=\(wsAuthenticatedOwner?.uuidString ?? "none") namespace=\(connectionNamespace.uuidString)"
                                )
                            } else if comm.kind == .subscribe {
                                logger.warning(
                                    "WS subscribe rejected requestID=\(wsRequestID) topic=\(comm.topic ?? "unknown") reason=\(err) owner=\(wsAuthenticatedOwner?.uuidString ?? "none") namespace=\(connectionNamespace.uuidString)"
                                )
                            }
                            await sendControlPayload(APILayer.harnessErrorPayload(message: err))
                        } else if comm.kind == .subscribe {
                            logger.info(
                                "WS subscribe accepted requestID=\(wsRequestID) topic=\(comm.topic ?? "unknown") owner=\(wsAuthenticatedOwner?.uuidString ?? "none") namespace=\(connectionNamespace.uuidString)"
                            )
                        }
                        }
                    }
                }
            }
            
            // Handle WebSocket disconnection
            let topicHubForClose = wireModelStateHub
            let conversationHubForClose = wireConversationEventsHub
            let conversationStateHubForClose = wireConversationStateHub
            let traceHubForClose = wireTraceHub
            let capabilityRegistryHubForClose = wireCapabilityRegistryHub
            let conversationsRegistryHubForClose = wireConversationsRegistryHub
            let subAgentLifecycleHubForClose = wireSubAgentLifecycleHub
            ws.onClose.whenComplete { _ in
                Task {
                    if let token = topicRegistration.modelTopicHubToken, let hub = topicHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.conversationEventsTopicHubToken, let hub = conversationHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.conversationStateTopicHubToken, let hub = conversationStateHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.subAgentLifecycleTopicHubToken, let hub = subAgentLifecycleHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.traceTopicHubToken, let hub = traceHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.capabilityRegistryTopicHubToken, let hub = capabilityRegistryHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    if let token = topicRegistration.conversationsRegistryTopicHubToken, let hub = conversationsRegistryHubForClose {
                        await hub.unregisterConnection(token)
                    }
                    await wireRuntime.apiCancelMessageStream()
                }
            }
        }
    }

    /// Split-gateway test seam (matches production ``setChatGatewayServices(_:)`` wiring).
    func configureRoutesForTesting(
        app: Application,
        conversation: APILayerConversationManaging,
        runtime: APILayerChatRuntimeManaging,
        modelProvider: APILayerModelManaging
    ) {
        let gateway = APILayerChatGatewayServices(conversation: conversation, runtime: runtime)
        configureRESTRoutes(app: app, chatGateway: gateway, modelManager: modelProvider)
        configureWebSocketRoutes(app: app, chatGateway: gateway, modelManager: modelProvider)
    }
}

/// Namespaced wire seams for split gateway dependencies.
enum APILayerChatWireSeams {
    typealias ConversationSession = APILayerConversationManaging
    typealias StreamingRuntime = APILayerChatRuntimeManaging
}

actor WebSocketOutboundSchemaViolationTracker {
    private let configuration: WebSocketOutboundSchemaEnforcementConfiguration
    private var violationTimes: [UInt64] = []

    init(configuration: WebSocketOutboundSchemaEnforcementConfiguration) {
        self.configuration = configuration
    }

    /// Records one violation and returns true when caller should disconnect.
    func recordViolation(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard configuration.enabled else { return false }
        let windowStart: UInt64 = now > configuration.windowNanoseconds ? now - configuration.windowNanoseconds : 0
        violationTimes.removeAll { $0 < windowStart }
        violationTimes.append(now)
        return violationTimes.count >= configuration.disconnectAfterViolations
    }
}

/// Holds per-`/ws` connection tokens for multiplexed topic hubs (model pool + conversation events + conversation state + capability registries).
final class WebSocketTopicWireRegistration: Sendable {
    private let modelBox = Mutex<ModelStateTopicHub.ConnectionToken?>(nil)
    private let conversationBox = Mutex<ConversationEventsTopicHub.ConnectionToken?>(nil)
    private let conversationStateBox = Mutex<ConversationStateTopicHub.ConnectionToken?>(nil)
    private let traceBox = Mutex<TraceTopicHub.ConnectionToken?>(nil)
    private let subAgentLifecycleBox = Mutex<SubAgentLifecycleTopicHub.ConnectionToken?>(nil)
    private let capabilityRegistryBox = Mutex<CapabilityRegistryTopicHub.ConnectionToken?>(nil)
    private let conversationsRegistryBox = Mutex<ConversationsRegistryTopicHub.ConnectionToken?>(nil)
    private let outboundFlowLimiterBox = Mutex<WebSocketHarnessOutboundFlowLimiter?>(nil)

    var outboundFlowLimiter: WebSocketHarnessOutboundFlowLimiter? {
        get { outboundFlowLimiterBox.withLock { $0 } }
        set { outboundFlowLimiterBox.withLock { $0 = newValue } }
    }

    var modelTopicHubToken: ModelStateTopicHub.ConnectionToken? {
        get { modelBox.withLock { $0 } }
        set { modelBox.withLock { $0 = newValue } }
    }

    var conversationEventsTopicHubToken: ConversationEventsTopicHub.ConnectionToken? {
        get { conversationBox.withLock { $0 } }
        set { conversationBox.withLock { $0 = newValue } }
    }

    var conversationStateTopicHubToken: ConversationStateTopicHub.ConnectionToken? {
        get { conversationStateBox.withLock { $0 } }
        set { conversationStateBox.withLock { $0 = newValue } }
    }

    var traceTopicHubToken: TraceTopicHub.ConnectionToken? {
        get { traceBox.withLock { $0 } }
        set { traceBox.withLock { $0 = newValue } }
    }

    var subAgentLifecycleTopicHubToken: SubAgentLifecycleTopicHub.ConnectionToken? {
        get { subAgentLifecycleBox.withLock { $0 } }
        set { subAgentLifecycleBox.withLock { $0 = newValue } }
    }

    var capabilityRegistryTopicHubToken: CapabilityRegistryTopicHub.ConnectionToken? {
        get { capabilityRegistryBox.withLock { $0 } }
        set { capabilityRegistryBox.withLock { $0 = newValue } }
    }

    var conversationsRegistryTopicHubToken: ConversationsRegistryTopicHub.ConnectionToken? {
        get { conversationsRegistryBox.withLock { $0 } }
        set { conversationsRegistryBox.withLock { $0 = newValue } }
    }
}

// MARK: - OAuth callback route (internal for testing)
extension APILayer {
    /// Registers GET /oauth/callback for OAuth redirects. Used by configureRESTRoutes and by tests.
    static func registerOAuthCallbackRoute(on app: Application, delivery: OAuthCallbackDelivery?, logger: Logger) {
        app.get("oauth", "callback") { req async -> Response in
            let code = try? req.query.get(String.self, at: "code")
            let state = try? req.query.get(String.self, at: "state")
            let error = try? req.query.get(String.self, at: "error")
            let errorDescription = try? req.query.get(String.self, at: "error_description")
            let result = OAuthCallbackServer.CallbackResult(
                authorizationCode: code,
                state: state,
                error: error,
                errorDescription: errorDescription
            )
            logger.debug("OAuth callback received (state: \(state ?? "none"), code length: \(code?.count ?? 0))")
            delivery?.deliver(result: result)
            let bodyText = result.isSuccess
                ? "✅ Authentication successful! You can close this window."
                : "❌ Authentication failed: \(error ?? "Unknown error")"
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>OAuth Callback</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f5; }
                    .container { background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; max-width: 400px; }
                </style>
            </head>
            <body><div class="container"><h1>Harness</h1><p>\(bodyText)</p></div></body>
            </html>
            """
            var headers = HTTPHeaders()
            headers.contentType = .html
            return Response(status: .ok, headers: headers, body: .init(string: html))
        }
    }
}

extension Model {
    
    func toModelInfo() -> ModelInfo {
        .init(
            id: id,
            modelName: modelName,
            modelProtocol: `protocol`,
            capabilities: capabilities,
            requestFeatures: requestFeatures,
            cost: cost,
            routing: routing
        )
    }
}

public enum APIError: Error, Equatable {
    /// Thrown when the API layer's required components aren't initialized
    case componentsNotInitialized

    /// Thrown when strict tenancy is enabled but no access-token validator is configured
    case authenticationNotConfigured
    
    /// Thrown when there's an error during server configuration
    case serverConfigurationError(String)

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.componentsNotInitialized, .componentsNotInitialized),
             (.authenticationNotConfigured, .authenticationNotConfigured):
            return true
        case (.serverConfigurationError(let a), .serverConfigurationError(let b)):
            return a == b
        default:
            return false
        }
    }
}

// Extension for sending structured data over WebSocket
extension WebSocket {
    func send(_ dictionary: [String: Any]) async throws {
        if let issue = WebSocketOutboundHarnessValidation.validationIssueForControlResponsePayload(dictionary) {
            throw APIError.serverConfigurationError(
                "Outbound control payload schema violation: \(issue.detail)"
            )
        }
        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let jsonString = String(data: data, encoding: .utf8) {
            try await self.send(jsonString)
        } else {
            throw APIError.serverConfigurationError("Failed to encode message")
        }
    }
}

extension ModelConversation {
    
    public func toAPILayerJSON() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id.uuidString,
            "modelName": modelName,
            "firstMessageContent": firstMessageContent,
            "messageCount": messageCount,
            "updatedAt": updatedAt.timeIntervalSince1970
        ]
        if let topic {
            payload["topic"] = topic
        }
        if let description {
            payload["description"] = description
        }
        payload["interactionMode"] = interactionMode.rawValue
        if let modeProfileID {
            payload["modeProfileID"] = modeProfileID
        }
        return payload
    }
}
