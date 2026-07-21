#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Vapor

public struct ContextCompactionPreviewAPISettings: Sendable {
    public var isRouteEnabled: Bool
    public var authToken: String?

    public init(isRouteEnabled: Bool, authToken: String?) {
        self.isRouteEnabled = isRouteEnabled
        self.authToken = authToken
    }

    public static let disabled = ContextCompactionPreviewAPISettings(isRouteEnabled: false, authToken: nil)
}

public struct HTTPPreconditionPolicySettings: Sendable {
    /// When true, guarded mutation routes require `If-Match` and return `428` when absent.
    public var strictMode: Bool

    public init(strictMode: Bool) {
        self.strictMode = strictMode
    }

    /// Canonical default: strict preconditions enabled for guarded mutation routes.
    public static let `default` = HTTPPreconditionPolicySettings(strictMode: true)
    /// Explicitly disables strict `If-Match` requirements on guarded mutation routes.
    public static let disabled = HTTPPreconditionPolicySettings(strictMode: false)
}

struct APILayerRouteDependencies: Sendable {
    let conversation: APILayerConversationManaging
    let runtime: APILayerChatRuntimeManaging
    let modelManager: APILayerModelManaging
    let logger: Logger
    let oauthCallbackDelivery: OAuthCallbackDelivery?
    let contextCompactionPreview: ContextCompactionPreviewAPISettings
    let httpPreconditions: HTTPPreconditionPolicySettings
    let tenancyPolicy: TenancyPolicySettings
    let modelStateTopicHub: ModelStateTopicHub?
    let modelInvocationCoordinator: ModelInvocationCoordinator?
    /// Maximum collected request body size for ``PUT …/engine-artifacts/:key``.
    let engineArtifactMaxBodyBytes: Int
    /// When set, notifies ``conversation/{id}/state`` subscribers after mutating conversation/session REST routes.
    let onConversationStateChanged: (@Sendable (UUID) async -> Void)?
    /// When set, publishes account/session conversation catalog mutations on `conversations/registry`.
    let onConversationsRegistryChanged: (@Sendable (ConversationRegistryChange.Kind, UUID) async -> Void)?

    init(
        gateway: APILayerChatGatewayServices,
        modelManager: APILayerModelManaging,
        logger: Logger,
        oauthCallbackDelivery: OAuthCallbackDelivery?,
        contextCompactionPreview: ContextCompactionPreviewAPISettings,
        httpPreconditions: HTTPPreconditionPolicySettings = .default,
        tenancyPolicy: TenancyPolicySettings = .disabled,
        modelStateTopicHub: ModelStateTopicHub? = nil,
        modelInvocationCoordinator: ModelInvocationCoordinator? = nil,
        engineArtifactMaxBodyBytes: Int = 16_777_216,
        onConversationStateChanged: (@Sendable (UUID) async -> Void)? = nil,
        onConversationsRegistryChanged: (@Sendable (ConversationRegistryChange.Kind, UUID) async -> Void)? = nil
    ) {
        self.conversation = gateway.conversation
        self.runtime = gateway.runtime
        self.modelManager = modelManager
        self.logger = logger
        self.oauthCallbackDelivery = oauthCallbackDelivery
        self.contextCompactionPreview = contextCompactionPreview
        self.httpPreconditions = httpPreconditions
        self.tenancyPolicy = tenancyPolicy
        self.modelStateTopicHub = modelStateTopicHub
        self.modelInvocationCoordinator = modelInvocationCoordinator
        self.engineArtifactMaxBodyBytes = max(1024, engineArtifactMaxBodyBytes)
        self.onConversationStateChanged = onConversationStateChanged
        self.onConversationsRegistryChanged = onConversationsRegistryChanged
    }

    init(
        chatManaging unified: APILayerChatManaging,
        modelManager: APILayerModelManaging,
        logger: Logger,
        oauthCallbackDelivery: OAuthCallbackDelivery?,
        contextCompactionPreview: ContextCompactionPreviewAPISettings,
        httpPreconditions: HTTPPreconditionPolicySettings = .default,
        tenancyPolicy: TenancyPolicySettings = .disabled,
        modelStateTopicHub: ModelStateTopicHub? = nil,
        modelInvocationCoordinator: ModelInvocationCoordinator? = nil,
        engineArtifactMaxBodyBytes: Int = 16_777_216,
        onConversationStateChanged: (@Sendable (UUID) async -> Void)? = nil,
        onConversationsRegistryChanged: (@Sendable (ConversationRegistryChange.Kind, UUID) async -> Void)? = nil
    ) {
        self.init(
            gateway: APILayerChatGatewayServices(unified: unified),
            modelManager: modelManager,
            logger: logger,
            oauthCallbackDelivery: oauthCallbackDelivery,
            contextCompactionPreview: contextCompactionPreview,
            httpPreconditions: httpPreconditions,
            tenancyPolicy: tenancyPolicy,
            modelStateTopicHub: modelStateTopicHub,
            modelInvocationCoordinator: modelInvocationCoordinator,
            engineArtifactMaxBodyBytes: engineArtifactMaxBodyBytes,
            onConversationStateChanged: onConversationStateChanged,
            onConversationsRegistryChanged: onConversationsRegistryChanged
        )
    }

    func notifyConversationStateChanged(_ conversationID: UUID) async {
        await onConversationStateChanged?(conversationID)
    }

    func notifyConversationsRegistryChanged(_ kind: ConversationRegistryChange.Kind, _ conversationID: UUID) async {
        await onConversationsRegistryChanged?(kind, conversationID)
    }
}

private struct ToolApprovalResolutionRequest: Content {
    let runID: UUID?
    let toolName: String
    let toolCallID: String?
    let route: ToolApprovalRoute?
    let status: ToolApprovalResolutionStatus
    let source: String?
    let reason: String?
    /// When true on an `approved` resolution, persists an allow-always tool rule so
    /// future runs auto-approve this tool.
    let durable: Bool?
    let arguments: JSON?
}

private struct ActiveSubAgentInvocationListResponse: Content {
    let items: [ActiveSubAgentInvocationInfo]
}

private struct CompletionAnnounceTriggerResponse: Content {
    let announceID: UUID
    let status: String
}

private struct AppendInputResponse: Content {
    let runId: UUID
    let messageId: UUID
}

protocol APILayerRESTEndpointModule {
    var moduleName: String { get }
    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies)
}

struct APILayerRESTModuleRegistry {
    let modules: [any APILayerRESTEndpointModule]

    func registerAll(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        for module in modules {
            dependencies.logger.info("Registering API REST module: \(module.moduleName)")
            module.registerRoutes(on: api, dependencies: dependencies)
        }
    }
}

struct APILayerCoreStatusPromptModule: APILayerRESTEndpointModule {
    let moduleName: String = "core.status_prompt"

    private struct StatusResponse: Content {
        let status: String
        let sessions: Int
    }

    private struct FullSystemPromptQuery: Content {
        let userSystemPrompt: String?
        /// Optional conversation UUID; when omitted, routing-only system prompt assembly uses no conversation context.
        let conversationID: String?
    }

    private struct FullSystemPromptResponse: Content {
        let fullSystemPrompt: String
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        api.get("status") { _ async -> StatusResponse in
            await StatusResponse(
                status: "running",
                sessions: dependencies.conversation.apiListConversationInfo().count
            )
        }

        api.get("system_prompt", "full") { req async throws -> FullSystemPromptResponse in
            let query = try? req.query.decode(FullSystemPromptQuery.self)
            let convoID = query?.conversationID.flatMap(UUID.init(uuidString:))
            let prompt = try await dependencies.conversation.apiGenerateFullSystemPrompt(conversationID: convoID, withUserSystemPrompt: query?.userSystemPrompt)
            return FullSystemPromptResponse(fullSystemPrompt: prompt)
        }
    }
}

struct APILayerCoreModelsModule: APILayerRESTEndpointModule {
    let moduleName: String = "core.models"

    private struct ListModelsResponse: Content {
        let models: [ModelInfo]
    }

    private struct ListModelsETagEntry: Encodable {
        let id: UUID
        let modelName: String
        let modelProtocol: ModelProtocol
        let capabilities: [LLMCapability]
    }

    private struct QueryModelsRequest: Content {
        var modelRef: String?
        var modelID: String?
        var idOrQuery: String?
    }

    private struct QueryModelsResponse: Content {
        var matches: [ModelInfo]
    }

    private struct ModelStateResponse: Content {
        let modelID: UUID
        let state: ModelStatePayload
    }

    private struct ModelCallsResponse: Content {
        let modelID: UUID
        let calls: ModelCallsPayload
    }

    private static func parseReference(from body: QueryModelsRequest) -> ModelReference? {
        let candidates = [body.modelRef, body.modelID, body.idOrQuery]
        for raw in candidates {
            guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { continue }
            if let ref = ModelReference.parse(token) {
                return ref
            }
        }
        return nil
    }

    private static func listModelsETagPayload(from models: [ModelInfo]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = models
            .map { model in
                return ListModelsETagEntry(
                    id: model.id,
                    modelName: model.modelName,
                    modelProtocol: model.modelProtocol,
                    capabilities: model.capabilities.sorted { $0.rawValue < $1.rawValue }
                )
            }
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
        return try encoder.encode(entries)
    }

    private static func modelIDParam(from req: Request) -> UUID? {
        guard let raw = req.parameters.get("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return UUID(uuidString: raw)
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        api.get("models") { req async throws -> Response in
            let models = await dependencies.modelManager.getAvailableModels().map { $0.toModelInfo() }
            let data = try JSONEncoder().encode(ListModelsResponse(models: models))
            let etag = APILayer.registryETag(payloadData: try Self.listModelsETagPayload(from: models))
            if APILayer.ifNoneMatchSatisfied(
                currentETag: etag,
                headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
            ) {
                return APILayer.notModifiedResponse(etag: etag)
            }
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            APILayer.addETag(etag, to: &headers)
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        api.post("models", "query") { req async -> Response in
            guard let body = try? req.content.decode(QueryModelsRequest.self),
                  let ref = Self.parseReference(from: body)
            else {
                return APILayerRESTErrorResponse.error(
                    status: .badRequest,
                    message: "Expected JSON body with one of: `modelRef`, `modelID`, or `idOrQuery`."
                )
            }
            do {
                let matches = try await dependencies.modelManager.resolveAll(ref).map { $0.toModel().toModelInfo() }
                let data = try JSONEncoder().encode(QueryModelsResponse(matches: matches))
                let etag = APILayer.modelQueryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(
                    status: .badRequest,
                    message: "Model query did not resolve any entries for the requested reference."
                )
            }
        }

        api.get("models", ":id", "state") { req async -> Response in
            guard let modelID = Self.modelIDParam(from: req),
                  let coordinator = dependencies.modelInvocationCoordinator
            else {
                return APILayerRESTErrorResponse.error(
                    status: .badRequest,
                    message: "Invalid model id or model state is unavailable."
                )
            }
            let state = await coordinator.snapshot(for: modelID)
            do {
                let data = try JSONEncoder().encode(ModelStateResponse(modelID: modelID, state: state))
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return Response(status: .internalServerError)
            }
        }

        api.get("models", ":id", "calls") { req async -> Response in
            guard let modelID = Self.modelIDParam(from: req),
                  let coordinator = dependencies.modelInvocationCoordinator
            else {
                return APILayerRESTErrorResponse.error(
                    status: .badRequest,
                    message: "Invalid model id or model calls are unavailable."
                )
            }
            let calls = await coordinator.callsSnapshot(for: modelID)
            do {
                let data = try JSONEncoder().encode(ModelCallsResponse(modelID: modelID, calls: calls))
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return Response(status: .internalServerError)
            }
        }

        api.get("models", ":id", "calls", "events") { req async -> Response in
            guard let modelID = Self.modelIDParam(from: req),
                  let coordinator = dependencies.modelInvocationCoordinator
            else {
                return APILayerRESTErrorResponse.error(
                    status: .badRequest,
                    message: "Invalid model id or model calls stream is unavailable."
                )
            }
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            response.body = .init(stream: { writer in
                Task {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    while !Task.isCancelled {
                        let snapshot = await coordinator.callsSnapshot(for: modelID)
                        if let data = try? encoder.encode(snapshot),
                           let json = String(data: data, encoding: .utf8) {
                            let line = "data: \(json)\n\n"
                            let buffer = ByteBuffer(data: Data(line.utf8))
                            _ = writer.write(.buffer(buffer))
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    _ = writer.write(.end)
                }
            })
            return response
        }
    }
}

struct APILayerConversationsModule: APILayerRESTEndpointModule {
    let moduleName: String = "conversations"

    private struct ConversationPlanResponse: Content {
        let markdown: String
        let exists: Bool
        let overview: String
        let goal: String
        let notes: String
        let tasks: [PlanTaskInput]
        let counts: PlanTaskCounts
        let inProgressTaskId: UUID?

        init(markdown: String) {
            let snapshot = PlanWireSnapshot.from(markdown: markdown, exists: true)
            self.markdown = markdown
            self.exists = snapshot.exists
            self.overview = snapshot.overview
            self.goal = snapshot.goal
            self.notes = snapshot.notes
            self.tasks = snapshot.tasks
            self.counts = snapshot.counts
            self.inProgressTaskId = snapshot.inProgressTaskId
        }
    }

    private struct PreviewContextCompactionRequest: Content {
        var forceRunCompactionLLM: Bool?
        var ignoreTokenThreshold: Bool?
        /// Base directory (tilde-expanded); optional. When set, each preview LLM run writes a UTC time-stamped subfolder with `summarizer-input.md` and `summarizer-output.md`. Preview/harness only.
        var compactionSummarizerDebugOutputPath: String?
    }

    private struct PreviewContextCompactionResponse: Content {
        let originalMessages: [Message]
        let compactedMessages: [Message]?
        let diagnostics: String?
        let messageProvenance: [ContextCompactionProvenanceEntry]?
        let noopReason: String?
    }

    private struct ManualContextCompactionRequest: Content {
        var reason: String?
    }

    private struct ManualContextCompactionResponse: Content {
        let originalMessages: [Message]
        let compactedMessages: [Message]?
        let diagnostics: String?
        let messageProvenance: [ContextCompactionProvenanceEntry]?
        let noopReason: String?
        let persisted: Bool
        let promptTokens: Int
        let thresholdTokens: Int
    }

    private struct EngineArtifactKeysResponse: Content {
        let keys: [String]
    }

    private static func validateEngineArtifactRouteKey(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw.removingPercentEncoding ?? raw
        return APISafeRelativeFilename.validate(key)
    }

    private static func parseConversationID(_ req: Request) -> UUID? {
        guard let uuidString = req.parameters.get("id") else { return nil }
        return UUID(uuidString: uuidString)
    }

    private static func requestID(_ req: Request) -> String {
        req.headers.first(name: "request-id")
            ?? req.headers.first(name: "x-request-id")
            ?? req.logger[metadataKey: "request-id"]?.description
            ?? "unknown"
    }

    private static func logConversationRouteNotFound(
        _ req: Request,
        dependencies: APILayerRouteDependencies,
        route: String,
        conversationID: UUID?
    ) {
        let id = conversationID?.uuidString ?? "invalid"
        dependencies.logger.warning("REST 404 route=\(route) requestID=\(requestID(req)) conversationID=\(id)")
    }

    private static func logPreconditionRequired(
        _ req: Request,
        dependencies: APILayerRouteDependencies,
        route: String,
        conversationID: UUID,
        currentETag: String?
    ) {
        dependencies.logger.warning(
            "REST 428 route=\(route) requestID=\(requestID(req)) conversationID=\(conversationID.uuidString) currentETag=\(currentETag ?? "none")"
        )
    }

    private static func logPreconditionFailed(
        _ req: Request,
        dependencies: APILayerRouteDependencies,
        route: String,
        conversationID: UUID,
        expectedETag: String,
        providedIfMatch: String
    ) {
        dependencies.logger.warning(
            "REST 412 route=\(route) requestID=\(requestID(req)) conversationID=\(conversationID.uuidString) currentETag=\(expectedETag) ifMatch=\(providedIfMatch)"
        )
    }

    private static func enforceConversationIfMatchPrecondition(
        req: Request,
        dependencies: APILayerRouteDependencies,
        conversationID: UUID,
        resourceURL: String
    ) async -> Response? {
        let conversation = await dependencies.conversation.apiGetConversation(id: conversationID)
        if conversation == nil {
            // Preserve canonical not-found behaviors from downstream handlers.
            return nil
        }
        let currentETag = APILayer.conversationETag(revision: conversation?.controlPlaneRevision ?? 0)
        let ifMatch = APILayer.ifMatchHeader(from: req.headers)
        if dependencies.httpPreconditions.strictMode, ifMatch == nil {
            return APILayer.preconditionRequiredResponse(resourceUrl: resourceURL, currentETag: currentETag)
        }
        if conversation != nil,
           let ifMatch,
           !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
            return APILayer.preconditionFailedResponse(
                currentETag: currentETag,
                yourVersion: ifMatch,
                resourceUrl: resourceURL
            )
        }
        return nil
    }

    private static func parseOptionalISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func parseTruthyQueryFlag(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    /// Non-empty owner strings must parse as UUIDs (avoid silent unscoped list/search).
    private static func parseOwnerQueryParameter(_ ownerString: String?) throws -> UUID? {
        guard let raw = ownerString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid `owner` query parameter; expected a UUID string.")
        }
        return id
    }

    private static func queryValues(for key: String, on req: Request) -> [String] {
        guard let query = req.url.query, !query.isEmpty else { return [] }
        return query
            .split(separator: "&")
            .compactMap { pair -> String? in
                let raw: Substring
                let value: Substring
                if let idx = pair.firstIndex(of: "=") {
                    raw = pair[..<idx]
                    value = pair[pair.index(after: idx)...]
                } else {
                    raw = pair
                    value = ""
                }
                guard String(raw).removingPercentEncoding == key else { return nil }
                return String(value).removingPercentEncoding
            }
    }

    private static func parseRunKindsQuery(_ req: Request) throws -> [ConversationRunKind]? {
        let values = queryValues(for: "kinds", on: req)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        var parsed: [ConversationRunKind] = []
        for value in values {
            guard let kind = ConversationRunKind(rawValue: value) else {
                throw Abort(.badRequest, reason: "Invalid `kinds` value: \(value)")
            }
            parsed.append(kind)
        }
        return parsed
    }

    private static func parseRunOutcomesQuery(_ req: Request) throws -> [ConversationRunOutcome]? {
        let values = queryValues(for: "outcomes", on: req)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        var parsed: [ConversationRunOutcome] = []
        for value in values {
            guard let outcome = ConversationRunOutcome(rawValue: value) else {
                throw Abort(.badRequest, reason: "Invalid `outcomes` value: \(value)")
            }
            parsed.append(outcome)
        }
        return parsed
    }

    private static func parseRunSinceQuery(_ req: Request) throws -> Date? {
        guard let raw = req.query[String.self, at: "since"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        guard let millis = Double(raw), millis.isFinite, millis >= 0 else {
            throw Abort(.badRequest, reason: "Invalid `since` query parameter; expected unix milliseconds.")
        }
        return Date(timeIntervalSince1970: millis / 1000.0)
    }

    /// `304` for run GET validators, with `Cache-Control: no-cache` so clients revalidate.
    private static func runResourceNotModifiedResponse(etag: String) -> Response {
        var response = APILayer.notModifiedResponse(etag: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }

    private static func conversationListQuery(from req: Request) throws -> ConversationListQuery {
        let limit = req.query[Int.self, at: "limit"] ?? 50
        let offset = req.query[Int.self, at: "offset"] ?? 0
        let includeArchived = req.query[Bool.self, at: "includeArchived"] ?? false
        let includeDeleted = req.query[Bool.self, at: "includeDeleted"] ?? false
        let search = req.query[String.self, at: "search"]
        let searchModeRaw = req.query[String.self, at: "searchMode"] ?? ConversationSearchMode.substring.rawValue
        let searchMode = ConversationSearchMode(rawValue: searchModeRaw) ?? .substring
        let sortRaw = req.query[String.self, at: "sort"] ?? ConversationListSort.updatedAtDesc.rawValue
        let sort = ConversationListSort(rawValue: sortRaw) ?? .updatedAtDesc
        let lifecycle: ConversationLifecycleState? = {
            guard let raw = req.query[String.self, at: "lifecycle"], let v = ConversationLifecycleState(rawValue: raw) else {
                return nil
            }
            return v
        }()
        let updatedAfter = parseOptionalISO8601(req.query[String.self, at: "updatedAfter"])
        let updatedBefore = parseOptionalISO8601(req.query[String.self, at: "updatedBefore"])
        let ownerAccountID = try parseOwnerQueryParameter(req.query[String.self, at: "owner"])
        var parentConversationID: UUID?
        if let raw = req.query[String.self, at: "parentConversationID"] {
            guard let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "Invalid parentConversationID query parameter.")
            }
            parentConversationID = id
        }
        var catalogSection: ConversationCatalogSection?
        if let raw = req.query[String.self, at: "catalogSection"] {
            guard let section = ConversationCatalogSection(rawValue: raw) else {
                throw Abort(.badRequest, reason: "Invalid catalogSection query parameter.")
            }
            catalogSection = section
        }
        let includeHidden = req.query[Bool.self, at: "includeHidden"] ?? false
        return ConversationListQuery(
            limit: limit,
            offset: offset,
            ownerAccountID: ownerAccountID,
            lifecycle: lifecycle,
            includeArchived: includeArchived,
            includeDeleted: includeDeleted,
            search: search,
            searchMode: searchMode,
            sort: sort,
            updatedAfter: updatedAfter,
            updatedBefore: updatedBefore,
            parentConversationID: parentConversationID,
            catalogSection: catalogSection,
            includeHidden: includeHidden
        )
    }

    private static func conversationSearchRequest(from req: Request) throws -> ConversationSearchRequest {
        let q = req.query[String.self, at: "q"] ?? ""
        let kindRaw = req.query[String.self, at: "kind"] ?? ConversationSearchKind.fulltext.rawValue
        let kind = ConversationSearchKind(rawValue: kindRaw) ?? .fulltext
        let limit = req.query[Int.self, at: "limit"] ?? 25
        let offset = req.query[Int.self, at: "offset"] ?? 0
        let includeArchived = req.query[Bool.self, at: "includeArchived"] ?? false
        let includeDeleted = req.query[Bool.self, at: "includeDeleted"] ?? false
        let ownerString = req.query[String.self, at: "owner"]
        let ownerAccountID = try parseOwnerQueryParameter(ownerString)
        return ConversationSearchRequest(
            query: q,
            kind: kind,
            limit: limit,
            offset: offset,
            ownerAccountID: ownerAccountID,
            includeArchived: includeArchived,
            includeDeleted: includeDeleted
        )
    }

    private static func conversationSearchHTTPResponse(
        req: Request,
        dependencies: APILayerRouteDependencies
    ) async throws -> Response {
        let searchReq = try conversationSearchRequest(from: req)
        let trimmed = searchReq.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return APILayerRESTErrorResponse.error(
                status: .badRequest,
                message: "Missing or empty required query parameter `q`."
            )
        }
        let (forbidden, resolvedOwner) = dependencies.tenancyResolveCollectionOwnerScope(
            explicitOwner: searchReq.ownerAccountID
        )
        if let forbidden { return forbidden }
        var scopedSearchReq = searchReq
        scopedSearchReq.ownerAccountID = resolvedOwner
        let page = await dependencies.conversation.apiSearchConversations(query: scopedSearchReq)
        do {
            let enc = JSONEncoder()
            let data = try enc.encode(page)
            let etag = APILayer.searchETag(payloadData: data)
            if APILayer.ifNoneMatchSatisfied(
                currentETag: etag,
                headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
            ) {
                return APILayer.notModifiedResponse(etag: etag)
            }
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            APILayer.addETag(etag, to: &headers)
            return Response(status: .ok, headers: headers, body: .init(data: data))
        } catch {
            dependencies.logger.error("Failed to encode conversation search response: \(error)")
            return Response(status: .internalServerError)
        }
    }

    static func conversationListHTTPResponse(
        req: Request,
        dependencies: APILayerRouteDependencies
    ) async throws -> Response {
        let requestID = req.headers.first(name: "request-id")
            ?? req.headers.first(name: "x-request-id")
            ?? req.logger[metadataKey: "request-id"]?.description
            ?? "unknown"
        dependencies.logger.warning("Handling GET /api/conversations request-id=\(requestID) query=\(req.url.query ?? "")")
        var query = try Self.conversationListQuery(from: req)
        let (forbidden, resolvedOwner) = dependencies.tenancyResolveCollectionOwnerScope(
            explicitOwner: query.ownerAccountID
        )
        if let forbidden { return forbidden }
        query.ownerAccountID = resolvedOwner
        let page = await dependencies.conversation.apiListConversations(query: query)
        let enc = JSONEncoder()
        let data = try enc.encode(page)
        let etag = APILayer.registryETag(payloadData: data)
        if APILayer.ifNoneMatchSatisfied(
            currentETag: etag,
            headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
        ) {
            return APILayer.notModifiedResponse(etag: etag)
        }
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        APILayer.addETag(etag, to: &headers)
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    private static func subAgentPoolErrorResponse(_ error: SubAgentPoolError) -> Response {
        switch error {
        case .lifecycleNotFound:
            return APILayerRESTErrorResponse.error(status: .notFound, message: "Sub-agent invocation not found")
        case .transportUnavailable:
            return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Sub-agent transport unavailable")
        case .unavailable:
            return APILayerRESTErrorResponse.error(status: .badRequest, message: "Sub-agent unavailable")
        case .admissionRejected(let reason):
            return APILayerRESTErrorResponse.error(status: .conflict, message: "Sub-agent admission rejected: \(reason)")
        case .operationFailed(let reason):
            return APILayerRESTErrorResponse.error(status: .badRequest, message: "Sub-agent operation failed: \(reason)")
        }
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        let conversationsPath = api.grouped("conversations")

        api.get("search") { req async throws -> Response in
            try await Self.conversationSearchHTTPResponse(req: req, dependencies: dependencies)
        }

        conversationsPath.get(":id", "events") { req async -> Response in
            guard let conversationID = Self.parseConversationID(req) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: conversationID) {
                return forbidden
            }
            let since = req.query[Int.self, at: "since"]
            do {
                let payload = try await dependencies.conversation.apiConversationEventsBackfill(
                    conversationID: conversationID,
                    since: since
                )
                let data = try JSONEncoder().encode(payload)
                let etag = APILayer.conversationEventsBackfillETag(
                    conversationID: conversationID,
                    latestSeq: payload.latestSeq,
                    since: since
                )
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("conversation events backfill failed: \(error)")
                return Response(status: .badRequest)
            }
        }

        conversationsPath.get(":id", "plan") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                let markdown = try await dependencies.conversation.apiReadPlanMarkdown(conversationID: uuid)
                let data = try JSONEncoder().encode(ConversationPlanResponse(markdown: markdown))
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                Self.logConversationRouteNotFound(
                    req,
                    dependencies: dependencies,
                    route: "/api/conversations/:id/plan",
                    conversationID: uuid
                )
                return APILayerRESTErrorResponse.error(status: .notFound, message: "\(error)")
            }
        }

        conversationsPath.get(":id", "tools") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                let tools = try await dependencies.conversation.apiListAvailableTools(conversationID: uuid)
                let data = try JSONEncoder().encode(tools)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    Self.logConversationRouteNotFound(
                        req,
                        dependencies: dependencies,
                        route: "/api/conversations/:id/tools",
                        conversationID: uuid
                    )
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "\(error)")
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.get(":id", "skills") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                let skills = try await dependencies.conversation.apiListAvailableSkills(conversationID: uuid)
                let data = try JSONEncoder().encode(skills)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    Self.logConversationRouteNotFound(
                        req,
                        dependencies: dependencies,
                        route: "/api/conversations/:id/skills",
                        conversationID: uuid
                    )
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "\(error)")
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.get(":id", "slash-commands") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                let rows = try await dependencies.conversation.apiListSlashCommands(conversationID: uuid)
                let data = try JSONEncoder().encode(rows)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    Self.logConversationRouteNotFound(
                        req,
                        dependencies: dependencies,
                        route: "/api/conversations/:id/slash-commands",
                        conversationID: uuid
                    )
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "\(error)")
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "preview-context-compaction") { req async -> Response in
            let compactPreview = dependencies.contextCompactionPreview
            guard compactPreview.isRouteEnabled else {
                return Response(status: .notFound)
            }
            guard let expectedToken = compactPreview.authToken, !expectedToken.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .forbidden, message: "Context compaction preview is enabled in config but no token is set; refusing requests.")
            }
            let header = req.headers["X-SAH-Context-Compaction-Preview-Token"].first
            guard let header, header == expectedToken else {
                return APILayerRESTErrorResponse.error(status: .unauthorized, message: "Invalid or missing X-SAH-Context-Compaction-Preview-Token header")
            }
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let requestBody = (try? req.content.decode(PreviewContextCompactionRequest.self)) ?? PreviewContextCompactionRequest()
            let gating = ContextCompactionGatingOptions(
                ignoreTokenThreshold: requestBody.ignoreTokenThreshold ?? false,
                forceRunCompactionLLM: requestBody.forceRunCompactionLLM ?? false
            )
            do {
                let result = try await dependencies.conversation.apiPreviewContextCompaction(
                    conversationID: uuid,
                    gating: gating,
                    summarizerDebugOutputPath: requestBody.compactionSummarizerDebugOutputPath
                )
                let response = PreviewContextCompactionResponse(
                    originalMessages: result.originalMessages,
                    compactedMessages: result.compactedMessages,
                    diagnostics: result.diagnostics,
                    messageProvenance: result.messageProvenance,
                    noopReason: result.noopReason
                )
                let data = try JSONEncoder().encode(response)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                await dependencies.notifyConversationStateChanged(uuid)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerChatPreviewError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Server chat provider does not support compaction preview")
            } catch is APILayerConversationRouteError {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            } catch {
                dependencies.logger.error("preview-context-compaction failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .internalServerError, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "compact") { req async -> Response in
            // `manualRESTEnabled` lives on `ContextCompactionConfiguration` (per-config), not on
            // `ServerConfig`; check it at request time so flipping the flag in PromptConfig.json
            // immediately takes effect without a restart.
            let manualEnabled = await dependencies.conversation.apiContextCompactionManualRESTEnabled()
            guard manualEnabled else {
                return Response(status: .notFound)
            }
            let compactPreview = dependencies.contextCompactionPreview
            guard let expectedToken = compactPreview.authToken, !expectedToken.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .forbidden, message: "Manual context compaction REST endpoint is enabled but no preview token is set; refusing requests.")
            }
            let header = req.headers["X-SAH-Context-Compaction-Preview-Token"].first
            guard let header, header == expectedToken else {
                return APILayerRESTErrorResponse.error(status: .unauthorized, message: "Invalid or missing X-SAH-Context-Compaction-Preview-Token header")
            }
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: uuid,
                resourceURL: "/api/conversations/\(uuid.uuidString)/compact"
            ) {
                return precondition
            }
            let body = (try? req.content.decode(ManualContextCompactionRequest.self)) ?? ManualContextCompactionRequest()
            do {
                let result = try await dependencies.conversation.apiPerformManualContextCompaction(
                    conversationID: uuid,
                    reason: body.reason
                )
                let response = ManualContextCompactionResponse(
                    originalMessages: result.originalMessages,
                    compactedMessages: result.compactedMessages,
                    diagnostics: result.diagnostics,
                    messageProvenance: result.messageProvenance,
                    noopReason: result.noopReason,
                    persisted: result.persisted,
                    promptTokens: result.promptTokens,
                    thresholdTokens: result.thresholdTokens
                )
                let data = try JSONEncoder().encode(response)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                await dependencies.notifyConversationStateChanged(uuid)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerChatPreviewError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Server chat provider does not support manual compaction")
            } catch is APILayerConversationRouteError {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            } catch {
                dependencies.logger.error("manual context compaction failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .internalServerError, message: "\(error)")
            }
        }

        conversationsPath.get(":id", "server-metadata") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .notFound)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let meta = await dependencies.conversation.apiGetConversationServerMetadata(conversationID: uuid) else {
                return Response(status: .notFound)
            }
            do {
                let data = try JSONEncoder().encode(meta)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("Failed to encode server-metadata: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.post(":id", "branch") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let body = try? req.content.decode(ConversationBranchRequest.self) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected JSON body with userMessageID")
            }
            let conversationExists = await dependencies.conversation.apiGetConversation(id: uuid) != nil
            let parentMessages = (try? await dependencies.conversation.apiListMessagesThrowing(conversationID: uuid)) ?? []
            let currentTailETag = APILayer.messageTailETag(lastMessageID: parentMessages.last?.id)
            let ifMatchBranch = APILayer.ifMatchHeader(from: req.headers)
            dependencies.logger.info("[APILayer] branch request parsed conversationID=\(uuid) anchorMessageID=\(body.userMessageID) strictPreconditions=\(dependencies.httpPreconditions.strictMode) ifMatch=\(ifMatchBranch ?? "nil") currentTailETag=\(currentTailETag) messageCount=\(parentMessages.count)")
            if dependencies.httpPreconditions.strictMode, ifMatchBranch == nil, conversationExists {
                return APILayer.preconditionRequiredResponse(
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/branch",
                    currentETag: currentTailETag
                )
            }
            if let ifMatch = ifMatchBranch,
               !APILayer.ifMatchSatisfied(currentETag: currentTailETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentTailETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/branch"
                )
            }
            do {
                dependencies.logger.info("[APILayer] branch dispatch conversationID=\(uuid) anchorMessageID=\(body.userMessageID)")
                let newID = try await dependencies.conversation.apiBranchConversation(
                    conversationID: uuid,
                    userMessageID: body.userMessageID
                )
                dependencies.logger.info("[APILayer] branch success sourceConversationID=\(uuid) childConversationID=\(newID)")
                await dependencies.notifyConversationStateChanged(uuid)
                await dependencies.notifyConversationStateChanged(newID)
                await dependencies.notifyConversationsRegistryChanged(.added, newID)
                let payload = ConversationBranchResponse(conversationID: newID)
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Branch not supported")
            } catch is APILayerConversationRouteError {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
                }
                if APILayerConversationRouteError.representsInvalidRevertTarget(error) {
                    return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid branch anchor")
                }
                dependencies.logger.error("[APILayer] branch failure conversationID=\(uuid) anchorMessageID=\(body.userMessageID) error=\(error)")
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "revert") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let body: ConversationRevertRequest
            do {
                body = try req.content.decode(ConversationRevertRequest.self)
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected JSON body with userMessageID")
            }

            let conversationExists = await dependencies.conversation.apiGetConversation(id: uuid) != nil
            let currentMessages = (try? await dependencies.conversation.apiListMessagesThrowing(conversationID: uuid)) ?? []
            let currentETag = APILayer.messageTailETag(lastMessageID: currentMessages.last?.id)
            let ifMatch = APILayer.ifMatchHeader(from: req.headers)
            let resourceURL = "/api/conversations/\(uuid.uuidString)/revert"
            if dependencies.httpPreconditions.strictMode, ifMatch == nil, conversationExists {
                return APILayer.preconditionRequiredResponse(resourceUrl: resourceURL, currentETag: currentETag)
            }
            if let ifMatch, !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentETag,
                    yourVersion: ifMatch,
                    resourceUrl: resourceURL
                )
            }

            do {
                let stream = try await dependencies.runtime.apiRevertToUserMessageAndStreamResponse(
                    conversationID: uuid,
                    messageID: body.userMessageID,
                    enableTools: body.includeTools != false,
                    enableAgents: body.includeAgents != false
                )
                return try await APILayer.streamingChatResponse(stream: stream)
            } catch {
                if let conflict = APILayer.restConflictResponse(for: error) {
                    return conflict
                }
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
                }
                if APILayerConversationRouteError.representsInvalidRevertTarget(error) {
                    return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid revert anchor")
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.get(":id", "sub-agents", "active") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let parentUUID = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: parentUUID) {
                return forbidden
            }
            do {
                let items = await dependencies.conversation.apiListActiveSubAgentInvocations(parentConversationID: parentUUID)
                let payload = ActiveSubAgentInvocationListResponse(items: items)
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("active sub-agent listing failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .internalServerError, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "sub-agents", ":lifecycleID", "cancel") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let parentUUID = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: parentUUID) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: parentUUID,
                resourceURL: "/api/conversations/\(parentUUID.uuidString)/sub-agents/\(req.parameters.get("lifecycleID") ?? "")/cancel"
            ) {
                return precondition
            }
            guard let lifecycleID = req.parameters.get("lifecycleID"), !lifecycleID.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid lifecycle ID")
            }
            do {
                try await dependencies.conversation.apiCancelActiveSubAgentInvocation(
                    parentConversationID: parentUUID,
                    lifecycleID: lifecycleID
                )
                await dependencies.notifyConversationStateChanged(parentUUID)
                return Response(status: .noContent)
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Sub-agent cancellation not supported")
            } catch let e as SubAgentPoolError {
                return Self.subAgentPoolErrorResponse(e)
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "Sub-agent invocation not found")
                }
                dependencies.logger.error("sub-agent cancellation failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .internalServerError, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "completion-announcements") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let conversationID = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: conversationID) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: conversationID,
                resourceURL: "/api/conversations/\(conversationID.uuidString)/completion-announcements"
            ) {
                return precondition
            }
            guard let body = try? req.content.decode(CompletionAnnounceTriggerRequest.self) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected CompletionAnnounceTriggerRequest JSON body")
            }
            let announce = CompletionAnnouncePayload(
                schemaVersion: CompletionAnnouncePayload.schemaVersionV1,
                announceID: body.announceID ?? UUID(),
                delegateHandleID: body.delegateHandleID,
                toolCallID: body.toolCallID,
                conversationID: conversationID,
                parentConversationID: body.parentConversationID,
                lifecycleID: body.lifecycleID,
                status: body.status,
                completedAt: body.completedAt ?? Date(),
                source: body.source ?? "api.rest.completionAnnounce",
                usage: body.usage,
                error: body.error
            )
            do {
                try await dependencies.conversation.apiPushCompletionAnnouncement(
                    conversationID: conversationID,
                    announce: announce,
                    toolMessageContent: body.toolMessageContent
                )
                await dependencies.notifyConversationStateChanged(conversationID)
                if let parent = announce.parentConversationID {
                    await dependencies.notifyConversationStateChanged(parent)
                }
                let payload = CompletionAnnounceTriggerResponse(announceID: announce.announceID, status: "accepted")
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Completion announce trigger not supported")
            } catch is APILayerConversationRouteError {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
                }
                dependencies.logger.error("completion announce trigger failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "tool-approvals") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let conversationID = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: conversationID) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: conversationID,
                resourceURL: "/api/conversations/\(conversationID.uuidString)/tool-approvals"
            ) {
                return precondition
            }
            guard let body = try? req.content.decode(ToolApprovalResolutionRequest.self) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected ToolApprovalResolutionRequest JSON body")
            }
            do {
                try await dependencies.conversation.apiResolveToolApproval(
                    conversationID: conversationID,
                    runID: body.runID,
                    toolName: body.toolName,
                    route: body.route ?? .user,
                    status: body.status,
                    source: body.source ?? "api.rest",
                    reason: body.reason,
                    durable: body.durable ?? false,
                    arguments: body.arguments
                )
                await dependencies.notifyConversationStateChanged(conversationID)
                return Response(status: .ok)
            } catch let error as ToolApprovalResolutionError {
                let message: String = switch error {
                case .ambiguousPendingApproval(let toolName, let pendingCount):
                    "ambiguous pending approval for \(toolName); supply arguments (\(pendingCount) pending)"
                case .pendingApprovalNotFound(let toolName):
                    "no pending approval found for \(toolName)"
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: message)
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Tool approval resolution not supported")
            } catch is APILayerConversationRouteError {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
                }
                dependencies.logger.error("tool approval resolution failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.post(":id", "checkpoints") { req async -> Response in
            guard let uuid = Self.parseConversationID(req) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let body = (try? req.content.decode(ConversationCheckpointInvalidateRequest.self)) ?? ConversationCheckpointInvalidateRequest()
            let kinds = body.kinds ?? []
            let kindForPrecondition = kinds.first ?? "context_compaction"
            let currentCheckpointEventID = await dependencies.conversation.apiGetLatestCheckpoint(conversationID: uuid, kind: kindForPrecondition)?.eventID
            let currentETag = APILayer.checkpointETag(kind: kindForPrecondition, lastCheckpointID: currentCheckpointEventID)
            let ifMatch = APILayer.ifMatchHeader(from: req.headers)
            if dependencies.httpPreconditions.strictMode, ifMatch == nil {
                return APILayer.preconditionRequiredResponse(
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/checkpoints",
                    currentETag: currentETag
                )
            }
            if let ifMatch,
               !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/checkpoints"
                )
            }
            do {
                try await dependencies.conversation.apiInvalidateConversationCheckpoints(conversationID: uuid, kinds: kinds)
                let resolved = kinds.isEmpty ? ["context_compaction"] : kinds
                await dependencies.notifyConversationStateChanged(uuid)
                let payload = ConversationCheckpointInvalidateResponse(kinds: resolved)
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationAPIError {
                return Response(status: .notImplemented)
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return Response(status: .notFound)
                }
                dependencies.logger.error("checkpoint mutation failed: \(error)")
                return Response(status: .badRequest)
            }
        }

        conversationsPath.get(":id", "checkpoints", "latest") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let kindParam = req.query[String.self, at: "kind"]
            guard let checkpoint = await dependencies.conversation.apiGetLatestCheckpoint(conversationID: uuid, kind: kindParam) else {
                return Response(status: .notFound)
            }
            let etag = APILayer.checkpointETag(kind: checkpoint.kind, lastCheckpointID: checkpoint.eventID)
            if APILayer.ifNoneMatchSatisfied(
                currentETag: etag,
                headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
            ) {
                return APILayer.notModifiedResponse(etag: etag)
            }
            do {
                let data = try JSONEncoder().encode(checkpoint)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("Failed to encode checkpoint: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.get(":id", "runs") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 200)
            let cursor = req.query[String.self, at: "cursor"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let cursor, !cursor.isEmpty, Data(base64Encoded: cursor) == nil {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid `cursor` query parameter.")
            }
            let filter: ConversationRunListFilter
            do {
                filter = try ConversationRunListFilter(
                    kinds: Self.parseRunKindsQuery(req),
                    outcomes: Self.parseRunOutcomesQuery(req),
                    since: Self.parseRunSinceQuery(req),
                    limit: limit,
                    cursor: cursor
                )
            } catch let abort as AbortError {
                return APILayerRESTErrorResponse.error(status: abort.status, message: abort.reason)
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid run list query")
            }
            let payload = await dependencies.runtime.apiListConversationRuns(conversationID: uuid, filter: filter)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(payload)
                let etag = APILayer.registryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return Self.runResourceNotModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("Failed to encode runs list: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.get(":id", "runs", ":runId") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let runString = req.parameters.get("runId"), let runID = UUID(uuidString: runString) else {
                return Response(status: .badRequest)
            }
            let includeDetail: Bool = {
                guard let raw = req.query[String.self, at: "detail"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(), !raw.isEmpty else {
                    return false
                }
                return raw == "1" || raw == "true" || raw == "yes"
            }()
            guard let run = await dependencies.runtime.apiGetConversationRun(
                conversationID: uuid,
                runID: runID,
                includeProjectionDetail: includeDetail
            ) else {
                return Response(status: .notFound)
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(run)
                let etag = APILayer.registryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return Self.runResourceNotModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("Failed to encode run: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.post(":id", "runs", ":runId", "cancel") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .badRequest)
            }
            guard let runString = req.parameters.get("runId"), let runID = UUID(uuidString: runString) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let conversation = await dependencies.conversation.apiGetConversation(id: uuid) else {
                return Response(status: .notFound)
            }
            let currentRunETag = APILayer.runETag(runID: conversation.currentRunID)
            if let ifMatch = APILayer.ifMatchHeader(from: req.headers),
               !APILayer.ifMatchSatisfied(currentETag: currentRunETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentRunETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/runs/\(runID.uuidString)/cancel"
                )
            }

            func jsonResponse<T: Encodable>(_ status: HTTPStatus, _ payload: T) -> Response {
                do {
                    let data = try JSONEncoder().encode(payload)
                    var headers = HTTPHeaders()
                    headers.add(name: .contentType, value: "application/json")
                    return Response(status: status, headers: headers, body: .init(data: data))
                } catch {
                    dependencies.logger.error("cancel run encode failed: \(error)")
                    return Response(status: .internalServerError)
                }
            }

            if conversation.currentRunID == runID {
                do {
                    try await dependencies.runtime.apiCancelRun(conversationID: uuid, runID: runID)
                    await dependencies.notifyConversationStateChanged(uuid)
                    return jsonResponse(.ok, CancelConversationRunResponse(runId: runID, outcome: .cancelled))
                } catch {
                    if !APILayerConversationRouteError.representsCancelRunNotActive(error) {
                        dependencies.logger.error("cancel run failed: \(error)")
                    }
                }
            }

            guard let run = await dependencies.runtime.apiGetConversationRun(
                conversationID: uuid,
                runID: runID,
                includeProjectionDetail: false
            ) else {
                return jsonResponse(
                    .conflict,
                    CancelConversationRunConflictBody(code: .runNotInFlight, runId: runID)
                )
            }
            if run.outcome == .cancelled {
                return jsonResponse(.ok, CancelConversationRunResponse(runId: runID, outcome: .cancelled))
            }
            if run.outcome == .completed || run.outcome == .errored || run.outcome == .bounded {
                return jsonResponse(
                    .conflict,
                    CancelConversationRunConflictBody(code: .runAlreadyEnded, runId: runID, outcome: run.outcome)
                )
            }
            return jsonResponse(
                .conflict,
                CancelConversationRunConflictBody(code: .runNotInFlight, runId: runID)
            )
        }

        // Canonical cancel route: explicit run id body with deterministic conflict semantics.
        conversationsPath.post(":id", "cancel") { req async -> Response in
            guard let uuid = Self.parseConversationID(req) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let conversation = await dependencies.conversation.apiGetConversation(id: uuid) else {
                return Response(status: .notFound)
            }
            guard let requestBody = try? req.content.decode(CancelConversationRunRequest.self) else {
                return Response(status: .badRequest)
            }
            let runID = requestBody.runId
            let currentRunETag = APILayer.runETag(runID: conversation.currentRunID)
            if let ifMatch = APILayer.ifMatchHeader(from: req.headers),
               !APILayer.ifMatchSatisfied(currentETag: currentRunETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentRunETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)/cancel"
                )
            }

            func jsonResponse<T: Encodable>(_ status: HTTPStatus, _ payload: T) -> Response {
                do {
                    let data = try JSONEncoder().encode(payload)
                    var headers = HTTPHeaders()
                    headers.add(name: .contentType, value: "application/json")
                    return Response(status: status, headers: headers, body: .init(data: data))
                } catch {
                    dependencies.logger.error("cancel current run encode failed: \(error)")
                    return Response(status: .internalServerError)
                }
            }

            if conversation.currentRunID == runID {
                do {
                    try await dependencies.runtime.apiCancelRun(conversationID: uuid, runID: runID)
                    await dependencies.notifyConversationStateChanged(uuid)
                    return jsonResponse(.ok, CancelConversationRunResponse(runId: runID, outcome: .cancelled))
                } catch {
                    if !APILayerConversationRouteError.representsCancelRunNotActive(error) {
                        dependencies.logger.error("cancel current run failed: \(error)")
                    }
                }
            }

            guard let run = await dependencies.runtime.apiGetConversationRun(
                conversationID: uuid,
                runID: runID,
                includeProjectionDetail: false
            ) else {
                return jsonResponse(
                    .conflict,
                    CancelConversationRunConflictBody(code: .runNotInFlight, runId: runID)
                )
            }
            if run.outcome == .cancelled {
                return jsonResponse(.ok, CancelConversationRunResponse(runId: runID, outcome: .cancelled))
            }
            if run.outcome == .completed || run.outcome == .errored || run.outcome == .bounded {
                return jsonResponse(
                    .conflict,
                    CancelConversationRunConflictBody(code: .runAlreadyEnded, runId: runID, outcome: run.outcome)
                )
            }
            return jsonResponse(
                .conflict,
                CancelConversationRunConflictBody(code: .runNotInFlight, runId: runID)
            )
        }

        conversationsPath.patch(":id") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            guard let currentConversation = await dependencies.conversation.apiGetConversation(id: uuid) else {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Conversation not found")
            }
            let currentETag = APILayer.conversationETag(revision: currentConversation.controlPlaneRevision)
            let ifMatch = APILayer.ifMatchHeader(from: req.headers)
            if dependencies.httpPreconditions.strictMode, ifMatch == nil {
                return APILayer.preconditionRequiredResponse(
                    resourceUrl: "/api/conversations/\(uuid.uuidString)",
                    currentETag: currentETag
                )
            }
            if let ifMatch,
               !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
                return APILayer.preconditionFailedResponse(
                    currentETag: currentETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)"
                )
            }
            do {
                var patch = try req.content.decode(ConversationPatch.self)
                if let ifMatchRevision = APILayer.parseConversationRevisionIfMatch(ifMatch) {
                    patch.expectedRevision = ifMatchRevision
                }
                var resolvedModel: Model?
                if patch.modelRef != nil || patch.userSystemPrompt != nil {
                    if let raw = patch.modelRef {
                        guard let ref = ModelReference.parse(raw) else {
                            return APILayerRESTErrorResponse.error(status: .badRequest, message: "Model not found: \(raw)")
                        }
                        let routed = await dependencies.conversation.apiComposeModelReferenceForRouting(
                            conversationID: uuid,
                            interactionMode: nil,
                            clientReference: ref
                        )
                        do {
                            resolvedModel = try await dependencies.modelManager.resolve(routed).toModel()
                        } catch {
                            return APILayerRESTErrorResponse.error(status: .badRequest, message: "Model not found: \(raw)")
                        }
                    }
                    guard resolvedModel != nil || patch.userSystemPrompt != nil else {
                        return APILayerRESTErrorResponse.error(status: .badRequest, message: "modelRef and userSystemPrompt cannot both be omitted")
                    }
                }
                let revision = try await dependencies.conversation.apiApplyConversationRESTPatch(
                    conversationID: uuid,
                    patch: patch,
                    resolvedModel: resolvedModel
                )
                await dependencies.notifyConversationStateChanged(uuid)
                let lifecycle = patch.lifecycle
                if let lifecycle {
                    switch lifecycle {
                    case .archived:
                        await dependencies.notifyConversationsRegistryChanged(.archived, uuid)
                    case .deleted:
                        await dependencies.notifyConversationsRegistryChanged(.deleted, uuid)
                    default:
                        await dependencies.notifyConversationsRegistryChanged(.updated, uuid)
                    }
                } else if patch.topic != nil || patch.description != nil || patch.metadata != nil
                    || patch.interactionMode != nil || patch.modeProfileID != nil {
                    await dependencies.notifyConversationsRegistryChanged(.updated, uuid)
                }
                let payload = ConversationPatchResponse(controlPlaneRevision: revision)
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                if let conflict = APILayer.restConflictResponse(for: error) {
                    return conflict
                }
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        conversationsPath.get(":id") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                Self.logConversationRouteNotFound(
                    req,
                    dependencies: dependencies,
                    route: "/api/conversations/:id",
                    conversationID: nil
                )
                return Response(status: .notFound)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let includeDerived = Self.parseTruthyQueryFlag(req.query[String.self, at: "includeDerived"])
            guard let conversation = await dependencies.conversation.apiGetConversation(id: uuid) else {
                Self.logConversationRouteNotFound(
                    req,
                    dependencies: dependencies,
                    route: "/api/conversations/:id",
                    conversationID: uuid
                )
                return Response(status: .notFound)
            }
            let baseETag = APILayer.conversationETag(revision: conversation.controlPlaneRevision)
            let etag = includeDerived ? "\(baseETag)-derived" : baseETag
            if APILayer.ifNoneMatchSatisfied(
                currentETag: etag,
                headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
            ) {
                return APILayer.notModifiedResponse(etag: etag)
            }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data: Data
                if includeDerived {
                    guard let withDerived = await dependencies.conversation.apiGetConversationWithDerived(id: uuid) else {
                        Self.logConversationRouteNotFound(
                            req,
                            dependencies: dependencies,
                            route: "/api/conversations/:id?includeDerived=true",
                            conversationID: uuid
                        )
                        return Response(status: .notFound)
                    }
                    data = try encoder.encode(withDerived)
                } else {
                    data = try encoder.encode(conversation)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                dependencies.logger.error("Failed to encode conversation: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.post(":id", "projection") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return Response(status: .badRequest)
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let payload = (try? req.content.decode(ConversationProjectRequest.self)) ?? ConversationProjectRequest()
            do {
                let projected = try await dependencies.conversation.apiProjectConversation(
                    conversationID: uuid,
                    request: payload
                )
                let data = try JSONEncoder().encode(projected)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationRouteError {
                return Response(status: .notFound)
            } catch is APILayerConversationAPIError {
                return Response(status: .notImplemented)
            } catch {
                dependencies.logger.error("conversation projection failed: \(error)")
                return Response(status: .badRequest)
            }
        }

        conversationsPath.post { req async throws -> Response in
            if let forbidden = dependencies.tenancyRespondIfCreateMutationForbidden() {
                return forbidden
            }
            let convoRequest = try req.content.decode(ConvoRequest.self)
            guard let rawRef = convoRequest.modelRef?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawRef.isEmpty,
                  let ref = ModelReference.parse(rawRef) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Model not found: missing or invalid modelRef")
            }
            let interactionMode: InteractionMode
            if let rawInteractionMode = convoRequest.interactionMode {
                guard let parsed = InteractionMode(rawValue: rawInteractionMode) else {
                    return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid interactionMode: \(rawInteractionMode)")
                }
                interactionMode = parsed
            } else {
                interactionMode = .chat
            }
            let modeProfileID: String? = {
                guard let raw = convoRequest.modeProfileID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                return raw
            }()
            let interactionModeForRouting: InteractionMode? = (convoRequest.interactionMode == nil && modeProfileID != nil) ? nil : interactionMode
            let routed = await dependencies.conversation.apiComposeModelReferenceForRouting(
                conversationID: nil,
                interactionMode: interactionModeForRouting,
                clientReference: ref
            )
            let model: Model
            do {
                model = try await dependencies.modelManager.resolve(routed).toModel()
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Model not found: \(rawRef)")
            }

            let newConversationID = try await dependencies.conversation.apiCreateConversation(
                with: model,
                userSystemPrompt: convoRequest.userSystemPrompt ?? "",
                topic: convoRequest.topic,
                description: convoRequest.description,
                metadata: convoRequest.metadata,
                interactionMode: interactionMode,
                modeProfileID: modeProfileID,
                cwd: convoRequest.cwd
            )
            await dependencies.notifyConversationStateChanged(newConversationID)
            await dependencies.notifyConversationsRegistryChanged(.added, newConversationID)
            let createResponse: [String: Any] = [
                "type": "create",
                "conversationID": newConversationID.uuidString,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: createResponse) {
                return Response(status: .ok, body: .init(data: data))
            } else {
                return APILayerRESTErrorResponse.error(status: .internalServerError, message: "Invalid response encoding")
            }
        }

        conversationsPath.delete(":id") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            let currentConversation = await dependencies.conversation.apiGetConversation(id: uuid)
            let currentETag = APILayer.conversationETag(revision: currentConversation?.controlPlaneRevision ?? 0)
            let ifMatch = APILayer.ifMatchHeader(from: req.headers)
            if dependencies.httpPreconditions.strictMode, ifMatch == nil, currentConversation != nil {
                Self.logPreconditionRequired(
                    req,
                    dependencies: dependencies,
                    route: "/api/conversations/:id",
                    conversationID: uuid,
                    currentETag: currentETag
                )
                return APILayer.preconditionRequiredResponse(
                    resourceUrl: "/api/conversations/\(uuid.uuidString)",
                    currentETag: currentETag
                )
            }
            if currentConversation != nil,
               let ifMatch,
               !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
                Self.logPreconditionFailed(
                    req,
                    dependencies: dependencies,
                    route: "/api/conversations/:id",
                    conversationID: uuid,
                    expectedETag: currentETag,
                    providedIfMatch: ifMatch
                )
                return APILayer.preconditionFailedResponse(
                    currentETag: currentETag,
                    yourVersion: ifMatch,
                    resourceUrl: "/api/conversations/\(uuid.uuidString)"
                )
            }
            let hard = req.query[Bool.self, at: "hard"] ?? true
            do {
                try await dependencies.conversation.apiDeleteConversation(conversationID: uuid, hard: hard)
            } catch {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "\(error)")
            }
            await dependencies.notifyConversationStateChanged(uuid)
            await dependencies.notifyConversationsRegistryChanged(.deleted, uuid)
            return Response(status: .ok)
        }

        conversationsPath.get(":id", "engine-artifacts") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                let keys = try await dependencies.conversation.apiListEngineArtifactKeys(conversationID: uuid)
                let payload = EngineArtifactKeysResponse(keys: keys)
                let data = try JSONEncoder().encode(payload)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Engine artifact store not available for this conversation")
            } catch {
                dependencies.logger.error("engine-artifacts list failed: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.get(":id", "engine-artifacts", ":key") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            guard let key = Self.validateEngineArtifactRouteKey(req.parameters.get("key")) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid engine artifact key")
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            do {
                guard let data = try await dependencies.conversation.apiGetEngineArtifact(conversationID: uuid, key: key) else {
                    return Response(status: .notFound)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/octet-stream")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Engine artifact store not available for this conversation")
            } catch {
                dependencies.logger.error("engine-artifacts get failed: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.put(":id", "engine-artifacts", ":key") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            guard let key = Self.validateEngineArtifactRouteKey(req.parameters.get("key")) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid engine artifact key")
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: uuid,
                resourceURL: "/api/conversations/\(uuid.uuidString)/engine-artifacts/\(key)"
            ) {
                return precondition
            }
            let maxBytes = dependencies.engineArtifactMaxBodyBytes
            let buffer: ByteBuffer?
            do {
                buffer = try await req.body.collect(max: maxBytes).get()
            } catch {
                return APILayerRESTErrorResponse.error(status: .payloadTooLarge, message: "Engine artifact body exceeds configured limit")
            }
            let bodyData: Data = {
                guard var buf = buffer else { return Data() }
                return Data(buffer: buf.readSlice(length: buf.readableBytes) ?? buf)
            }()
            do {
                try await dependencies.conversation.apiPutEngineArtifact(conversationID: uuid, key: key, data: bodyData)
                await dependencies.notifyConversationStateChanged(uuid)
                return Response(status: .noContent)
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Engine artifact store not available for this conversation")
            } catch {
                dependencies.logger.error("engine-artifacts put failed: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.delete(":id", "engine-artifacts", ":key") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            guard let key = Self.validateEngineArtifactRouteKey(req.parameters.get("key")) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid engine artifact key")
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: uuid,
                resourceURL: "/api/conversations/\(uuid.uuidString)/engine-artifacts/\(key)"
            ) {
                return precondition
            }
            do {
                try await dependencies.conversation.apiEvictEngineArtifacts(conversationID: uuid, key: key)
                await dependencies.notifyConversationStateChanged(uuid)
                return Response(status: .noContent)
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Engine artifact store not available for this conversation")
            } catch {
                dependencies.logger.error("engine-artifacts delete failed: \(error)")
                return Response(status: .internalServerError)
            }
        }

        conversationsPath.delete(":id", "engine-artifacts") { req async -> Response in
            guard let uuidString = req.parameters.get("id"), let uuid = UUID(uuidString: uuidString) else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: uuid) {
                return forbidden
            }
            if let precondition = await Self.enforceConversationIfMatchPrecondition(
                req: req,
                dependencies: dependencies,
                conversationID: uuid,
                resourceURL: "/api/conversations/\(uuid.uuidString)/engine-artifacts"
            ) {
                return precondition
            }
            do {
                try await dependencies.conversation.apiEvictEngineArtifacts(conversationID: uuid, key: nil)
                await dependencies.notifyConversationStateChanged(uuid)
                return Response(status: .noContent)
            } catch is APILayerConversationAPIError {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Engine artifact store not available for this conversation")
            } catch {
                dependencies.logger.error("engine-artifacts evict-all failed: \(error)")
                return Response(status: .internalServerError)
            }
        }

        // Canonical spec-shaped message append route.
        conversationsPath.post(":id", "messages") { req async throws -> Response in
            guard let conversationID = Self.parseConversationID(req) else {
                throw Abort(.badRequest, reason: "Invalid conversation ID")
            }
            let chatRequest = try req.content.decode(ChatRequest.self)
            return try await APILayerMessagesModule.sendMessageResponse(
                req: req,
                dependencies: dependencies,
                chatRequest: chatRequest,
                forcedConversationID: conversationID
            )
        }
    }
}

enum APILayerImageLoader {
    static func loadImages(names: [String], logger: Logger) -> [Message.Image] {
        var images: [Message.Image] = []
        let tempDir = FileManager.default.temporaryDirectory
        let blobStore: SessionBlobStore? = SessionPersistenceConfiguration.sessionStoreRoot.map {
            SessionBlobStore(root: $0, maxBytes: SessionPersistenceConfiguration.blobMaxBytes)
        }

        for filename in names {
            if let blobStore {
                let blobId = SessionBlobImageRef.parsePath(filename) ?? (filename.count == 64 ? filename.lowercased() : nil)
                if let blobId, let data = try? blobStore.get(blobId: blobId) {
                    images.append(
                        Message.Image(
                            name: filename,
                            path: SessionBlobImageRef.path(for: blobId),
                            imageData: data,
                            thumbData: data
                        )
                    )
                    continue
                }
                logger.warning("Warning: Could not load blob image: \(filename)")
                continue
            }

            guard let fileURL = APISafeRelativeFilename.resolveContainedFileURL(root: tempDir, relativeName: filename) else {
                logger.warning("Warning: Could not read image file: \(filename)")
                continue
            }
            guard FileManager.default.fileExists(atPath: fileURL.path), let data = try? Data(contentsOf: fileURL) else {
                logger.warning("Warning: Could not read image file: \(filename)")
                continue
            }
            let thumbData: Data? = {
#if canImport(AppKit)
                if let nsImage = NSImage(data: data) {
                    return nsImage.resize(50, 50)?.jpegData(compressionQuality: 0.8)
                } else {
                    return nil
                }
#elseif canImport(UIKit)
                if let uiImage = UIImage(data: data) {
                    return uiImage.resize(50, 50).jpegData(compressionQuality: 0.8)
                } else {
                    return nil
                }
#endif
            }()
            images.append(Message.Image(name: filename, path: fileURL.absoluteString, imageData: data, thumbData: thumbData))
        }

        return images
    }
}

struct APILayerMessagesModule: APILayerRESTEndpointModule {
    let moduleName: String = "messages"

    static func sendMessageResponse(
        req: Request,
        dependencies: APILayerRouteDependencies,
        chatRequest: ChatRequest,
        forcedConversationID: UUID
    ) async throws -> Response {
        try await APISessionContext.$servingRESTRequest.withValue(true) {
            try await sendMessageResponseUnnested(
                req: req,
                dependencies: dependencies,
                chatRequest: chatRequest,
                forcedConversationID: forcedConversationID
            )
        }
    }

    private static func sendMessageResponseUnnested(
        req: Request,
        dependencies: APILayerRouteDependencies,
        chatRequest: ChatRequest,
        forcedConversationID: UUID
    ) async throws -> Response {
        let routingConversationID = forcedConversationID

        if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: routingConversationID) {
            return forbidden
        }
        let currentMessages: [Message] = (try? await dependencies.conversation.apiListMessagesThrowing(conversationID: routingConversationID)) ?? []
        let currentTailMessageID = currentMessages.last?.id
        let currentETag = APILayer.messageTailETag(lastMessageID: currentTailMessageID)
        let ifMatch = APILayer.ifMatchHeader(from: req.headers)
        let resourceURL = "/api/conversations/\(routingConversationID.uuidString)/messages"
        if dependencies.httpPreconditions.strictMode, ifMatch == nil {
            return APILayer.preconditionRequiredResponse(resourceUrl: resourceURL, currentETag: currentETag)
        }
        if let ifMatch,
           !APILayer.ifMatchSatisfied(currentETag: currentETag, headerValue: ifMatch) {
            return APILayer.preconditionFailedResponse(
                currentETag: currentETag,
                yourVersion: ifMatch,
                resourceUrl: resourceURL
            )
        }

        let images = APILayerImageLoader.loadImages(names: chatRequest.imageNames, logger: dependencies.logger)
        let inputTrustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(chatRequest.inputTrust)
        let resolvedTrustClass = MessageInputTrustCodec.safePolicyClass(raw: inputTrustRaw)
        let expectedTail = ifMatch != nil
            ? APILayer.parseMessageTailIfMatch(ifMatch)
            : chatRequest.expectedPreviousTailHarnessMessageID
        let configuration = MessageOutputTurnConfiguration.forRESTSend(
            enableTools: chatRequest.includeTools != false,
            enableAgents: chatRequest.includeAgents != false,
            expectedPreviousTailHarnessMessageID: expectedTail,
            inputTrustRaw: inputTrustRaw,
            resolvedInputTrustClass: resolvedTrustClass,
            originSurface: chatRequest.originSurface,
            originSenderID: chatRequest.originSenderID
        )
        do {
            let stream = try await APILayer.acquireChatStream(
                message: chatRequest.message,
                images: images,
                chatRuntime: dependencies.runtime,
                conversationID: routingConversationID,
                configuration: configuration
            )
            let runID = stream.runID ?? UUID()
            let messageID = stream.messageID ?? UUID()
            // Canonical append route returns anchors immediately; drain the stream so runtime
            // completion side-effects (message persistence/topic fanout) are not gated on an HTTP consumer.
            Task {
                var chunkCount = 0
                var textChunkCount = 0
                var textChars = 0
                for await partial in stream.partialContent {
                    chunkCount += 1
                    switch partial {
                    case .text(let text):
                        textChunkCount += 1
                        textChars += text.count
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=text chars=\(text.count)"
                        )
                    case .reasoning(let text, let blockIndex):
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=reasoning chars=\(text.count) blockIndex=\(blockIndex.map(String.init) ?? "nil")"
                        )
                    case .toolCall(let toolName, let toolCallId, let argumentsFragment, let blockIndex):
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=toolCall toolName=\(toolName ?? "nil") toolCallId=\(toolCallId ?? "nil") argumentChars=\(argumentsFragment?.count ?? 0) blockIndex=\(blockIndex.map(String.init) ?? "nil")"
                        )
                    case .toolCallStarted(let toolName, let toolCallId, let contentIndex):
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=toolCallStarted toolName=\(toolName ?? "nil") toolCallId=\(toolCallId ?? "nil") contentIndex=\(contentIndex.map(String.init) ?? "nil")"
                        )
                    case .toolCallCompleted(let toolName, let toolCallId, let arguments, let blockIndex):
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=toolCallCompleted toolName=\(toolName ?? "nil") toolCallId=\(toolCallId ?? "nil") argumentChars=\(arguments.count) blockIndex=\(blockIndex.map(String.init) ?? "nil")"
                        )
                    case .surfaceIntent(let intent):
                        dependencies.logger.debug(
                            "appendInput drain chunk conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) index=\(chunkCount) kind=surfaceIntent filePath=\(intent.filePath)"
                        )
                    }
                }
                dependencies.logger.debug(
                    "appendInput drain complete conversationID=\(routingConversationID.uuidString) runID=\(runID.uuidString) chunks=\(chunkCount) textChunks=\(textChunkCount) textChars=\(textChars)"
                )
            }
            let payload = AppendInputResponse(runId: runID, messageId: messageID)
            let data = try JSONEncoder().encode(payload)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .created, headers: headers, body: .init(data: data))
        } catch {
            if let conflict = APILayer.restConflictResponse(for: error) {
                return conflict
            }
            dependencies.logger.error("send message failed: \(error)")
            return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
        }
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
    }
}

/// Canonical top-level registry reads.
struct APILayerCapabilitiesModule: APILayerRESTEndpointModule {
    let moduleName: String = "capabilities"

    private static func toolRegistryETagPayload(from tools: [AvailableToolInfo]) throws -> Data {
        let stableNames = Array(Set(tools.map(\.name))).sorted()
        return try JSONEncoder().encode(stableNames)
    }

    private static func modeDTOs(from rows: [ModeProfilePickerRow]) -> [ModeProfileDTO] {
        rows.map { row in
            ModeProfileDTO(
                id: row.id,
                label: row.label,
                description: row.description,
                symbol: row.symbol,
                summary: row.summary
            )
        }
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        api.get("tools") { req async -> Response in
            do {
                let tools = try await dependencies.conversation.apiListAvailableTools()
                let data = try JSONEncoder().encode(tools)
                let etag = APILayer.registryETag(payloadData: try Self.toolRegistryETagPayload(from: tools))
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        api.get("skills") { req async -> Response in
            do {
                let skills = try await dependencies.conversation.apiListAvailableSkills()
                let data = try JSONEncoder().encode(skills)
                let etag = APILayer.registryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        api.get("sub-agents") { req async -> Response in
            do {
                let subAgents = try await dependencies.conversation.apiListSubAgentRegistryEntries()
                let data = try JSONEncoder().encode(subAgents)
                let etag = APILayer.registryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        api.get("modes") { req async -> Response in
            do {
                let rows = try await dependencies.conversation.apiListModeProfiles()
                let payload = ModesCatalogResponse(profiles: Self.modeDTOs(from: rows))
                let data = try JSONEncoder().encode(payload)
                let etag = APILayer.registryETag(payloadData: data)
                if APILayer.ifNoneMatchSatisfied(
                    currentETag: etag,
                    headerValue: APILayer.ifNoneMatchHeader(from: req.headers)
                ) {
                    return APILayer.notModifiedResponse(etag: etag)
                }
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                APILayer.addETag(etag, to: &headers)
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }

        api.post("modes", "reload") { _ async -> Response in
            do {
                let reloaded = try await dependencies.conversation.apiReloadModeProfiles()
                let data = try JSONEncoder().encode(["reloaded": reloaded])
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }
    }
}

struct APILayerTracesModule: APILayerRESTEndpointModule {
    let moduleName: String = "traces"

    private struct TraceQuery: Content {
        let limit: Int?
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        api.get("traces", ":conversationId") { req async -> Response in
            guard let raw = req.parameters.get("conversationId"),
                  let conversationID = UUID(uuidString: raw)
            else {
                return APILayerRESTErrorResponse.invalidConversationID()
            }
            if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(conversationID: conversationID) {
                return forbidden
            }
            let query = try? req.query.decode(TraceQuery.self)
            do {
                let response = try await dependencies.conversation.apiListConversationTraceSpans(
                    conversationID: conversationID,
                    limit: query?.limit
                )
                let data = try JSONEncoder().encode(response)
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json")
                return Response(status: .ok, headers: headers, body: .init(data: data))
            } catch APILayerConversationAPIError.unsupported {
                return APILayerRESTErrorResponse.error(status: .notImplemented, message: "Trace fetch is not supported by this chat provider")
            } catch {
                if APILayerConversationRouteError.representsConversationNotFound(error) {
                    return Response(status: .notFound)
                }
                dependencies.logger.error("trace fetch failed: \(error)")
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "\(error)")
            }
        }
    }
}

struct APILayerUploadModule: APILayerRESTEndpointModule {
    let moduleName: String = "upload"

    private struct FileUploadResponse: Content {
        let filename: String
        let size: Int
        let contentType: String
        let blobId: String?
        let filePath: String?
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        api.post("upload") { req async throws -> FileUploadResponse in
            guard let file = req.body.data else {
                throw Abort(.badRequest, reason: "No file data found")
            }

            guard let filenameHeader = req.headers.first(name: "X-File-Name"),
                  let contentType = req.headers.first(name: "Content-Type")
            else {
                throw Abort(.badRequest, reason: "Missing required headers: X-File-Name and Content-Type")
            }

            let data = Data(buffer: file)
            if let root = SessionPersistenceConfiguration.sessionStoreRoot {
                let store = SessionBlobStore(root: root, maxBytes: SessionPersistenceConfiguration.blobMaxBytes)
                let ref = try store.put(
                    data: data,
                    durability: .ephemeral,
                    originalName: filenameHeader,
                    mimeTypeHint: contentType,
                    trust: "user-direct",
                    ttlSeconds: SessionPersistenceConfiguration.blobDefaultEphemeralTTLSeconds,
                    lane: .inbound
                )
                return FileUploadResponse(
                    filename: filenameHeader,
                    size: data.count,
                    contentType: contentType,
                    blobId: ref.id,
                    filePath: SessionBlobImageRef.path(for: ref.id)
                )
            }

            guard let safeFilename = APISafeRelativeFilename.validate(filenameHeader) else {
                throw Abort(.badRequest, reason: "Invalid X-File-Name")
            }

            let uniqueFilename = "\(UUID().uuidString)_\(safeFilename)"
            let tempDir = FileManager.default.temporaryDirectory
            guard let fileURL = APISafeRelativeFilename.resolveContainedFileURL(root: tempDir, relativeName: uniqueFilename) else {
                throw Abort(.badRequest, reason: "Invalid upload filename")
            }
            try data.write(to: fileURL)

            return FileUploadResponse(
                filename: uniqueFilename,
                size: data.count,
                contentType: contentType,
                blobId: nil,
                filePath: fileURL.path
            )
        }
    }
}

struct APILayerExecApprovalsModule: APILayerRESTEndpointModule {
    let moduleName: String = "exec-approvals"

    private struct ExecApprovalResolutionRequest: Content {
        var approved: Bool
        var durable: Bool?
        var reason: String?
    }

    /// Unified resolve body on the spec's decision vocabulary. `decision` is
    /// preferred (`allowOnce`/`allowAlways`/`deny`); `approved`/`durable` remain for
    /// the deprecated exec-only alias.
    private struct UnifiedApprovalResolutionRequest: Content {
        var decision: String?
        var approved: Bool?
        var durable: Bool?
        var reason: String?
    }

    private struct ExecApprovalGrantsResponse: Content {
        var commandNames: [String]
    }

    func registerRoutes(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        let execApprovalsPath = api.grouped("exec-approvals")

        // Static `grants` routes must be registered before `:id` so that the
        // path segment is not captured as an approval ID.
        execApprovalsPath.get("grants") { _ async -> ExecApprovalGrantsResponse in
            let commandNames = await ExecApprovalStore.shared.listDurableGrants()
            return ExecApprovalGrantsResponse(commandNames: commandNames)
        }

        execApprovalsPath.delete("grants", ":commandName") { req async -> Response in
            let raw = req.parameters.get("commandName")
            let commandName = (raw?.removingPercentEncoding ?? raw)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !commandName.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid command name")
            }
            let revoked = await ExecApprovalStore.shared.revokeDurableGrant(commandName: commandName)
            guard revoked else {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Exec approval grant not found")
            }
            return Response(status: .ok)
        }

        execApprovalsPath.post(":id") { req async -> Response in
            guard let id = req.parameters.get("id"), !id.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid exec approval ID")
            }
            guard let body = try? req.content.decode(ExecApprovalResolutionRequest.self) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected ExecApprovalResolutionRequest JSON body")
            }
            let store = ExecApprovalStore.shared
            switch await Self.resolveExecApprovalViaREST(
                id: id,
                dependencies: dependencies,
                store: store,
                approved: body.approved,
                durable: body.durable ?? false,
                reason: body.reason ?? "denied via api.rest"
            ) {
            case .forbidden(let response):
                return response
            case .notFound:
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Exec approval not found")
            case .resolved:
                return Response(status: .ok)
            }
        }

        // Unified resolve endpoint (spec: one POST /approvals/:id on the shared
        // decision vocabulary). The path-specific endpoints above and the tool
        // endpoint remain as aliases during migration.
        let approvalsPath = api.grouped("approvals")
        approvalsPath.post(":id") { req async -> Response in
            guard let id = req.parameters.get("id"), !id.isEmpty else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Invalid approval ID")
            }
            guard let body = try? req.content.decode(UnifiedApprovalResolutionRequest.self) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected UnifiedApprovalResolutionRequest JSON body")
            }
            let decision: ApprovalDecision
            if let token = body.decision, let parsed = ApprovalDecision.fromToken(token) {
                decision = parsed
            } else if let approved = body.approved {
                decision = approved ? (body.durable == true ? .allowAlways : .allowOnce) : .deny
            } else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: "Expected a decision (allowOnce|allowAlways|deny) or approved flag")
            }
            let store = ExecApprovalStore.shared
            let approved: Bool
            let durable: Bool
            switch decision {
            case .allowOnce:
                approved = true
                durable = false
            case .allowAlways:
                approved = true
                durable = true
            case .deny, .timeout, .cancelled:
                approved = false
                durable = false
            }
            switch await Self.resolveExecApprovalViaREST(
                id: id,
                dependencies: dependencies,
                store: store,
                approved: approved,
                durable: durable,
                reason: body.reason ?? "denied via api.rest"
            ) {
            case .forbidden(let response):
                return response
            case .notFound:
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Approval not found")
            case .resolved:
                return Response(status: .ok)
            }
        }
    }

    private enum ExecApprovalRESTResolveOutcome {
        case resolved(ExecApprovalResolution)
        case notFound
        case forbidden(Response)
    }

    private static func resolveExecApprovalViaREST(
        id: String,
        dependencies: APILayerRouteDependencies,
        store: ExecApprovalStore,
        approved: Bool,
        durable: Bool,
        reason: String?
    ) async -> ExecApprovalRESTResolveOutcome {
        guard let pendingScope = await store.pendingScope(id: id) else {
            return .notFound
        }
        if let forbidden = await dependencies.tenancyRespondIfConversationAccessForbidden(
            conversationID: pendingScope.conversationID
        ) {
            return .forbidden(forbidden)
        }
        let strictTenancy = dependencies.tenancyPolicy.requireAuthenticatedOwnerOnMutations
        guard let resolution = await store.resolve(
            id: id,
            scope: pendingScope,
            strictTenancy: strictTenancy,
            ownerScope: APISessionContext.authenticatedOwnerAccountID,
            approved: approved,
            durable: durable,
            reason: reason
        ) else {
            return .notFound
        }
        return .resolved(resolution)
    }
}
