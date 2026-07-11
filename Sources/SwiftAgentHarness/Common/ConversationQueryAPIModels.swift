import EasyJSON
import Foundation
import SwiftAgentKit

// MARK: - List

public enum ConversationListSort: String, Codable, Sendable, CaseIterable {
    case updatedAtDesc
    case updatedAtAsc
    case createdAtDesc
    case createdAtAsc
}

/// How `search` is interpreted for paged conversation list queries.
public enum ConversationSearchMode: String, Codable, Sendable, CaseIterable {
    /// Topic, description, tags (existing behavior).
    case substring
    /// Includes message body text (full transcript scan on in-memory registry — suitable for harness parity; optional FTS index later).
    case fts
}

public struct ConversationListQuery: Codable, Sendable, Equatable {
    public var limit: Int
    public var offset: Int
    /// When set, only conversations owned by this account are listed (multi-tenant); mirrors ``ConversationSearchRequest/ownerAccountID``.
    public var ownerAccountID: UUID?
    /// When set, only rows with this lifecycle are included (and inclusion flags are not used for filtering).
    public var lifecycle: ConversationLifecycleState?
    public var includeArchived: Bool
    public var includeDeleted: Bool
    public var search: String?
    /// Controls whether ``search`` matches metadata only or also message bodies (see ``ConversationSearchMode``).
    public var searchMode: ConversationSearchMode
    public var sort: ConversationListSort
    public var updatedAfter: Date?
    public var updatedBefore: Date?
    /// When set, only conversations whose ``ModelConversation/parentConversationID`` matches are listed (children of that parent).
    public var parentConversationID: UUID?
    /// When set to `automations`, lists system-origin root conversations (trigger hosts).
    public var catalogSection: ConversationCatalogSection?
    /// When true, includes sub-agent and other hidden catalog rows (debug/admin).
    public var includeHidden: Bool

    public init(
        limit: Int = 50,
        offset: Int = 0,
        ownerAccountID: UUID? = nil,
        lifecycle: ConversationLifecycleState? = nil,
        includeArchived: Bool = false,
        includeDeleted: Bool = false,
        search: String? = nil,
        searchMode: ConversationSearchMode = .substring,
        sort: ConversationListSort = .updatedAtDesc,
        updatedAfter: Date? = nil,
        updatedBefore: Date? = nil,
        parentConversationID: UUID? = nil,
        catalogSection: ConversationCatalogSection? = nil,
        includeHidden: Bool = false
    ) {
        self.limit = limit
        self.offset = offset
        self.ownerAccountID = ownerAccountID
        self.lifecycle = lifecycle
        self.includeArchived = includeArchived
        self.includeDeleted = includeDeleted
        self.search = search
        self.searchMode = searchMode
        self.sort = sort
        self.updatedAfter = updatedAfter
        self.updatedBefore = updatedBefore
        self.parentConversationID = parentConversationID
        self.catalogSection = catalogSection
        self.includeHidden = includeHidden
    }

    public var catalogVisibilityFilter: ConversationCatalogVisibilityFilter {
        if includeHidden { return .allIncludingHidden }
        if catalogSection == .automations { return .automationsOnly }
        return .primaryOnly
    }

    public static let `default` = ConversationListQuery()
}

/// Request body for `POST /conversations/:id/branch` (fork at user message).
public struct ConversationBranchRequest: Codable, Sendable, Equatable {
    public var userMessageID: UUID

    public init(userMessageID: UUID) {
        self.userMessageID = userMessageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .userMessageID) {
            userMessageID = id
            return
        }
        if let id = try container.decodeIfPresent(UUID.self, forKey: .fromEntryId) {
            userMessageID = id
            return
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .fromEntryId),
           let id = UUID(uuidString: raw) {
            userMessageID = id
            return
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .userMessageID),
           let id = UUID(uuidString: raw) {
            userMessageID = id
            return
        }
        throw DecodingError.keyNotFound(
            CodingKeys.userMessageID,
            .init(codingPath: decoder.codingPath, debugDescription: "userMessageID or fromEntryId required")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userMessageID, forKey: .userMessageID)
    }

    private enum CodingKeys: String, CodingKey {
        case userMessageID
        case fromEntryId
    }
}

/// Request body for `POST /conversations/:id/revert` (in-place truncate at user message + regenerate).
public struct ConversationRevertRequest: Codable, Sendable, Equatable {
    public var userMessageID: UUID
    public var includeTools: Bool?
    public var includeAgents: Bool?

    public init(userMessageID: UUID, includeTools: Bool? = nil, includeAgents: Bool? = nil) {
        self.userMessageID = userMessageID
        self.includeTools = includeTools
        self.includeAgents = includeAgents
    }
}

/// Request body for checkpoint mutation (`POST …/checkpoints`).
public struct ConversationCheckpointInvalidateRequest: Codable, Sendable, Equatable {
    /// Harness checkpoint kinds to invalidate (e.g. `context_compaction`). Empty or omitted → server default.
    public var kinds: [String]?

    public init(kinds: [String]? = nil) {
        self.kinds = kinds
    }
}

/// Response for `POST …/branch`.
public struct ConversationBranchResponse: Codable, Sendable, Equatable {
    public var conversationID: UUID

    public init(conversationID: UUID) {
        self.conversationID = conversationID
    }
}

// MARK: - Sub-agents (`POST …/sub-agents`)

/// Normalized launch context for sub-agent execution.
public enum SubAgentLaunchContext: String, Codable, Sendable, CaseIterable {
    case fork
    case isolated
}

/// Query constraints for selecting a delegate sub-agent by capabilities.
public struct SubAgentQuery: Codable, Sendable, Equatable {
    public var text: String?
    public var transportKinds: [String]?
    public var useClasses: [String]?
    public var permissionPolicies: [String]?
    public var trustLevels: [String]?
    public var requiresStreaming: Bool?
    public var requiresLongRunning: Bool?
    /// Optional hosted persona scope for routing.
    public var hostPersonaID: String?
    /// Optional auth scope tags required by the caller.
    public var authScopeTags: [String]?
    /// Optional coarse routing partition selector.
    public var routingDomain: String?
    /// Optional tenant isolation selector.
    public var tenantScope: String?

    public init(
        text: String? = nil,
        transportKinds: [String]? = nil,
        useClasses: [String]? = nil,
        permissionPolicies: [String]? = nil,
        trustLevels: [String]? = nil,
        requiresStreaming: Bool? = nil,
        requiresLongRunning: Bool? = nil,
        hostPersonaID: String? = nil,
        authScopeTags: [String]? = nil,
        routingDomain: String? = nil,
        tenantScope: String? = nil
    ) {
        self.text = text
        self.transportKinds = transportKinds
        self.useClasses = useClasses
        self.permissionPolicies = permissionPolicies
        self.trustLevels = trustLevels
        self.requiresStreaming = requiresStreaming
        self.requiresLongRunning = requiresLongRunning
        self.hostPersonaID = hostPersonaID
        self.authScopeTags = authScopeTags
        self.routingDomain = routingDomain
        self.tenantScope = tenantScope
    }
}

/// Structured reference for sub-agent resolution.
public struct SubAgentReference: Codable, Sendable, Equatable {
    public var id: String?
    public var slug: String?
    public var query: SubAgentQuery?

    public init(id: String? = nil, slug: String? = nil, query: SubAgentQuery? = nil) {
        self.id = id
        self.slug = slug
        self.query = query
    }

    public func preferredIdentifier() -> String? {
        id ?? slug
    }
}

/// Launch request payload for nested conversation orchestration.
public struct SubAgentSpawnRequest: Codable, Sendable {
    /// Normalized launch context (`fork` or `isolated`).
    public var context: SubAgentLaunchContext?
    /// Required when ``context`` is ``fork``.
    public var userMessageID: UUID?
    /// Optional short task label.
    public var taskDescription: String?
    /// Optional full task brief.
    public var prompt: String?
    /// Optional sub-agent class/category selector.
    public var subagentType: String?
    /// Optional pre-existing agent identifier.
    public var agentID: String?
    /// Optional explicit agent reference alias (id or slug-like handle).
    public var agentRef: String?
    /// Optional capability query used when no explicit agent identifier is provided.
    public var agentQuery: SubAgentQuery?
    /// Optional hosted persona context for routing policy checks.
    public var hostPersonaID: String?
    /// Optional auth scopes asserted by the caller.
    public var authScopeTags: [String]?
    /// Optional coarse routing domain for isolation.
    public var routingDomain: String?
    /// Optional tenant scope for policy isolation.
    public var tenantScope: String?
    /// Optional model override (UUID or slug) for isolated spawn; ignored for fork.
    public var modelRef: String?
    /// Optional async launch preference.
    public var runInBackground: Bool?
    public var userSystemPrompt: String?
    public var topic: String?
    public var description: String?
    public var metadata: JSON?
    public var interactionMode: String?
    /// Optional closed-world tool allowlist applied to the child as `routingPrefs.explicitToolPolicy`.
    /// `nil` leaves routing policy unset (mode profile alone). Empty array denies all tools.
    public var toolsAllow: [String]?

    private enum CodingKeys: String, CodingKey {
        case context
        case userMessageID
        case taskDescription
        case prompt
        case subagentType
        case agentID
        case agentId
        case agentRef
        case agentQuery
        case hostPersonaID
        case authScopeTags
        case routingDomain
        case tenantScope
        case modelRef
        case runInBackground
        case userSystemPrompt
        case topic
        case description
        case metadata
        case interactionMode
        case toolsAllow
    }

    public init(
        context: SubAgentLaunchContext? = nil,
        userMessageID: UUID? = nil,
        taskDescription: String? = nil,
        prompt: String? = nil,
        subagentType: String? = nil,
        agentID: String? = nil,
        agentRef: String? = nil,
        agentQuery: SubAgentQuery? = nil,
        hostPersonaID: String? = nil,
        authScopeTags: [String]? = nil,
        routingDomain: String? = nil,
        tenantScope: String? = nil,
        modelRef: String? = nil,
        runInBackground: Bool? = nil,
        userSystemPrompt: String? = nil,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: String? = nil,
        toolsAllow: [String]? = nil
    ) {
        self.context = context
        self.userMessageID = userMessageID
        self.taskDescription = taskDescription
        self.prompt = prompt
        self.subagentType = subagentType
        self.agentID = agentID
        self.agentRef = agentRef
        self.agentQuery = agentQuery
        self.hostPersonaID = hostPersonaID
        self.authScopeTags = authScopeTags
        self.routingDomain = routingDomain
        self.tenantScope = tenantScope
        self.modelRef = modelRef
        self.runInBackground = runInBackground
        self.userSystemPrompt = userSystemPrompt
        self.topic = topic
        self.description = description
        self.metadata = metadata
        self.interactionMode = interactionMode
        self.toolsAllow = toolsAllow
    }

    public func resolvedContext() -> SubAgentLaunchContext {
        context ?? .isolated
    }

    public func preferredAgentRef() -> String? {
        agentRef ?? agentID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = try c.decodeIfPresent(SubAgentLaunchContext.self, forKey: .context)
        userMessageID = try c.decodeIfPresent(UUID.self, forKey: .userMessageID)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
            ?? c.decodeIfPresent(String.self, forKey: .agentId)
        agentRef = try c.decodeIfPresent(String.self, forKey: .agentRef)
        agentQuery = try c.decodeIfPresent(SubAgentQuery.self, forKey: .agentQuery)
        hostPersonaID = try c.decodeIfPresent(String.self, forKey: .hostPersonaID)
        authScopeTags = try c.decodeIfPresent([String].self, forKey: .authScopeTags)
        routingDomain = try c.decodeIfPresent(String.self, forKey: .routingDomain)
        tenantScope = try c.decodeIfPresent(String.self, forKey: .tenantScope)
        modelRef = try c.decodeIfPresent(String.self, forKey: .modelRef)
        runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground)
        userSystemPrompt = try c.decodeIfPresent(String.self, forKey: .userSystemPrompt)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        metadata = try c.decodeIfPresent(JSON.self, forKey: .metadata)
        interactionMode = try c.decodeIfPresent(String.self, forKey: .interactionMode)
        toolsAllow = try c.decodeIfPresent([String].self, forKey: .toolsAllow)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encodeIfPresent(userMessageID, forKey: .userMessageID)
        try c.encodeIfPresent(taskDescription, forKey: .taskDescription)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(subagentType, forKey: .subagentType)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encodeIfPresent(agentRef, forKey: .agentRef)
        try c.encodeIfPresent(agentQuery, forKey: .agentQuery)
        try c.encodeIfPresent(hostPersonaID, forKey: .hostPersonaID)
        try c.encodeIfPresent(authScopeTags, forKey: .authScopeTags)
        try c.encodeIfPresent(routingDomain, forKey: .routingDomain)
        try c.encodeIfPresent(tenantScope, forKey: .tenantScope)
        try c.encodeIfPresent(modelRef, forKey: .modelRef)
        try c.encodeIfPresent(runInBackground, forKey: .runInBackground)
        try c.encodeIfPresent(userSystemPrompt, forKey: .userSystemPrompt)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(interactionMode, forKey: .interactionMode)
        try c.encodeIfPresent(toolsAllow, forKey: .toolsAllow)
    }
}

/// Ack payload for checkpoint invalidation.
public struct ConversationCheckpointInvalidateResponse: Codable, Sendable, Equatable {
    public var kinds: [String]

    public init(kinds: [String]) {
        self.kinds = kinds
    }
}

// MARK: - Read / Projection control-plane parity

/// Journal event wire for control-plane conversation reads (`includeDerived=true`) and projection metadata.
public struct ConversationJournalEventWire: Codable, Sendable, Equatable {
    public var eventID: Int
    public var kind: String
    public var payloadJSON: String
    public var basedOnEventID: Int?
    public var coversStartEventID: Int?
    public var coversEndEventID: Int?
    public var createdAt: Date
    public var journalStream: ConversationJournalStream
    public var streamSequence: Int

    public init(
        eventID: Int,
        kind: String,
        payloadJSON: String,
        basedOnEventID: Int? = nil,
        coversStartEventID: Int? = nil,
        coversEndEventID: Int? = nil,
        createdAt: Date,
        journalStream: ConversationJournalStream,
        streamSequence: Int
    ) {
        self.eventID = eventID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.basedOnEventID = basedOnEventID
        self.coversStartEventID = coversStartEventID
        self.coversEndEventID = coversEndEventID
        self.createdAt = createdAt
        self.journalStream = journalStream
        self.streamSequence = streamSequence
    }
}

/// Additive read payload for `GET /conversations/{id}?includeDerived=true`.
public struct ConversationReadWithDerivedResponse: Codable, Sendable {
    public var conversation: ModelConversation
    public var rawEvents: [Message]
    public var derivedEvents: [ConversationJournalEventWire]

    public init(
        conversation: ModelConversation,
        rawEvents: [Message],
        derivedEvents: [ConversationJournalEventWire]
    ) {
        self.conversation = conversation
        self.rawEvents = rawEvents
        self.derivedEvents = derivedEvents
    }
}

/// Optional control-plane projection config payload.
public struct ConversationProjectionConfig: Codable, Sendable {
    /// Reserved passthrough for assembly/projection overrides; schema intentionally open.
    public var options: JSON?

    public init(options: JSON? = nil) {
        self.options = options
    }
}

/// Request body for `POST /conversations/{id}/projection`.
public struct ConversationProjectRequest: Codable, Sendable {
    public var config: ConversationProjectionConfig?

    public init(config: ConversationProjectionConfig? = nil) {
        self.config = config
    }
}

public struct ConversationProjectionMetadata: Codable, Sendable {
    public var frontierEventID: Int
    public var rawEventCount: Int
    public var derivedEventCount: Int
    public var config: ConversationProjectionConfig?

    public init(
        frontierEventID: Int,
        rawEventCount: Int,
        derivedEventCount: Int,
        config: ConversationProjectionConfig? = nil
    ) {
        self.frontierEventID = frontierEventID
        self.rawEventCount = rawEventCount
        self.derivedEventCount = derivedEventCount
        self.config = config
    }
}

/// Response body for `POST /conversations/{id}/projection`.
public struct ConversationProjectResponse: Codable, Sendable {
    public var projectedMessages: [Message]
    public var metadata: ConversationProjectionMetadata
    public var assembledSystemPrompt: String?
    public var systemPromptReplaySpecDigest: String?
    public var sectionProvenance: [String: String]?

    public init(
        projectedMessages: [Message],
        metadata: ConversationProjectionMetadata,
        assembledSystemPrompt: String? = nil,
        systemPromptReplaySpecDigest: String? = nil,
        sectionProvenance: [String: String]? = nil
    ) {
        self.projectedMessages = projectedMessages
        self.metadata = metadata
        self.assembledSystemPrompt = assembledSystemPrompt
        self.systemPromptReplaySpecDigest = systemPromptReplaySpecDigest
        self.sectionProvenance = sectionProvenance
    }
}

public struct ConversationListSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var modelName: String
    public var topic: String?
    public var description: String?
    public var messageCount: Int
    public var createdAt: String
    public var updatedAt: String
    public var lifecycle: ConversationLifecycleState
    public var tags: [String]
    /// Monotonic control-plane revision for ``PATCH`` optimistic concurrency (see ``ConversationPatch/expectedRevision``).
    public var controlPlaneRevision: UInt64

    public init(
        id: UUID,
        modelName: String,
        topic: String?,
        description: String?,
        messageCount: Int,
        createdAt: String,
        updatedAt: String,
        lifecycle: ConversationLifecycleState,
        tags: [String],
        controlPlaneRevision: UInt64 = 0
    ) {
        self.id = id
        self.modelName = modelName
        self.topic = topic
        self.description = description
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lifecycle = lifecycle
        self.tags = tags
        self.controlPlaneRevision = controlPlaneRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, modelName, topic, description, messageCount, createdAt, updatedAt, lifecycle, tags, controlPlaneRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        modelName = try c.decode(String.self, forKey: .modelName)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        lifecycle = try c.decode(ConversationLifecycleState.self, forKey: .lifecycle)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        controlPlaneRevision = try c.decodeIfPresent(UInt64.self, forKey: .controlPlaneRevision) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(modelName, forKey: .modelName)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lifecycle, forKey: .lifecycle)
        try c.encode(tags, forKey: .tags)
        try c.encode(controlPlaneRevision, forKey: .controlPlaneRevision)
    }
}

public struct PagedConversationsResponse: Codable, Sendable, Equatable {
    public var items: [ConversationListSummary]
    public var totalCount: Int
    public var nextOffset: Int?

    public init(items: [ConversationListSummary], totalCount: Int, nextOffset: Int?) {
        self.items = items
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }
}

// MARK: - Cross-conversation search (`GET /search`)

/// Wire encoding for search kind (`fulltext` vs reserved `semantic`).
public enum ConversationSearchKind: String, Codable, Sendable, CaseIterable {
    case fulltext
    case semantic
}

/// Control-plane search over persisted message bodies (SwiftData `CachedMessage`).
public struct ConversationSearchRequest: Codable, Sendable, Equatable {
    /// Normalized search string (from query param `q`).
    public var query: String
    public var kind: ConversationSearchKind
    public var limit: Int
    public var offset: Int
    /// When set, only conversations owned by this account are searched (multi-tenant).
    public var ownerAccountID: UUID?
    public var includeArchived: Bool
    public var includeDeleted: Bool

    public init(
        query: String,
        kind: ConversationSearchKind = .fulltext,
        limit: Int = 25,
        offset: Int = 0,
        ownerAccountID: UUID? = nil,
        includeArchived: Bool = false,
        includeDeleted: Bool = false
    ) {
        self.query = query
        self.kind = kind
        self.limit = limit
        self.offset = offset
        self.ownerAccountID = ownerAccountID
        self.includeArchived = includeArchived
        self.includeDeleted = includeDeleted
    }
}

public struct ConversationSearchHit: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var messageID: UUID
    public var excerpt: String
    /// Heuristic relevance score (higher is better); not comparable across server versions.
    public var score: Double?
    /// 1-based order within this response page.
    public var rank: Int?
    public var conversationTopic: String?

    public init(
        conversationID: UUID,
        messageID: UUID,
        excerpt: String,
        score: Double? = nil,
        rank: Int? = nil,
        conversationTopic: String? = nil
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.excerpt = excerpt
        self.score = score
        self.rank = rank
        self.conversationTopic = conversationTopic
    }
}

public struct ConversationSearchResponse: Codable, Sendable, Equatable {
    public var hits: [ConversationSearchHit]
    public var totalHitCount: Int
    public var warning: String?
    public var nextOffset: Int?

    public init(hits: [ConversationSearchHit], totalHitCount: Int, warning: String? = nil, nextOffset: Int? = nil) {
        self.hits = hits
        self.totalHitCount = totalHitCount
        self.warning = warning
        self.nextOffset = nextOffset
    }
}

// MARK: - Patch

/// Partial update for `PATCH /conversations/:id`. Omitted keys leave fields unchanged.
public struct ConversationPatch: Codable, Sendable {
    public var topic: String?
    public var description: String?
    public var metadata: JSON?
    public var interactionMode: InteractionMode?
    /// Optional persisted registry pointer for mode policy resolution.
    public var modeProfileID: String?
    public var routingModelOptions: ConversationRoutingModelOptions?
    public var lifecycle: ConversationLifecycleState?
    /// Canonical model ref (UUID or registry slug).
    public var modelRef: String?
    public var userSystemPrompt: String?
    /// Must match ``ModelConversation/controlPlaneRevision`` on the server (otherwise `409`).
    public var expectedRevision: UInt64
    /// Conversation-level routing tool policy (harness `routing.toolWhitelist`). Intersects with mode profile tools.
    public var routingToolPolicy: ConversationExplicitToolPolicy?

    public init(
        expectedRevision: UInt64,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode? = nil,
        modeProfileID: String? = nil,
        routingModelOptions: ConversationRoutingModelOptions? = nil,
        lifecycle: ConversationLifecycleState? = nil,
        modelRef: String? = nil,
        userSystemPrompt: String? = nil,
        routingToolPolicy: ConversationExplicitToolPolicy? = nil
    ) {
        self.topic = topic
        self.description = description
        self.metadata = metadata
        self.interactionMode = interactionMode
        self.modeProfileID = modeProfileID
        self.routingModelOptions = routingModelOptions
        self.lifecycle = lifecycle
        self.modelRef = modelRef
        self.userSystemPrompt = userSystemPrompt
        self.expectedRevision = expectedRevision
        self.routingToolPolicy = routingToolPolicy
    }
}

/// Successful `PATCH /conversations/:id` response body (JSON).
public struct ConversationPatchResponse: Codable, Sendable, Equatable {
    public var type: String
    public var controlPlaneRevision: UInt64

    public init(type: String = "update", controlPlaneRevision: UInt64) {
        self.type = type
        self.controlPlaneRevision = controlPlaneRevision
    }
}

// MARK: - Compaction checkpoint (wire)

/// Public checkpoint snapshot for REST (`GET .../checkpoints/latest`). Mirrors persisted compaction payload fields.
public struct ContextCompactionCheckpointWire: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var kind: String
    public var coveredMessageIDs: [UUID]
    public var syntheticMessages: [ContextCompactionSyntheticMessageWire]
    public var configFingerprint: String
    public var basedOnEventID: Int
    public var basedOnTailMessageID: UUID?
    public var strategyRawValue: String?
    public var cachePolicyFingerprint: String?
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        kind: String,
        coveredMessageIDs: [UUID],
        syntheticMessages: [ContextCompactionSyntheticMessageWire],
        configFingerprint: String,
        basedOnEventID: Int,
        basedOnTailMessageID: UUID?,
        strategyRawValue: String? = nil,
        cachePolicyFingerprint: String? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.coveredMessageIDs = coveredMessageIDs
        self.syntheticMessages = syntheticMessages
        self.configFingerprint = configFingerprint
        self.basedOnEventID = basedOnEventID
        self.basedOnTailMessageID = basedOnTailMessageID
        self.strategyRawValue = strategyRawValue
        self.cachePolicyFingerprint = cachePolicyFingerprint
        self.createdAt = createdAt
    }
}

public struct ContextCompactionSyntheticMessageWire: Codable, Sendable, Equatable {
    public var id: UUID
    public var role: String
    public var content: String

    public init(id: UUID, role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
