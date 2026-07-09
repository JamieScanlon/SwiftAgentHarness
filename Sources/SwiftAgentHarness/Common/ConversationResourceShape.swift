//
//  Harness-aligned conversation **resource** fields (distinct from streaming ``ModelState``).
//

import Foundation

// MARK: - Lifecycle (resource)

/// Persisted conversation lifecycle — not to be confused with ``ModelState`` (generation UI).
public enum ConversationLifecycleState: String, Codable, Sendable, CaseIterable {
    case active
    case suspended
    case archived
    case deleted
}

// MARK: - Run status (resource)

/// High-level run status for the conversation resource (harness `state.runStatus`).
/// Maps from orchestration / agent loop; see server comments near persistence writes.
public enum ConversationResourceRunStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case awaitingApproval
    case errored
}

// MARK: - Prompt

/// Split system prompt vs appended instructions (harness `prompt.systemOverride` / `extraInstructions`).
/// `systemOverride` maps to the persisted system prompt / first system message content.
public struct ConversationPromptFields: Codable, Sendable, Equatable {
    public var systemOverride: String
    public var extraInstructions: String?

    public init(systemOverride: String, extraInstructions: String? = nil) {
        self.systemOverride = systemOverride
        self.extraInstructions = extraInstructions
    }
}

// MARK: - Routing preferences

/// Persisted routing prefs (`routing.modelQuery`-compatible subset + tool policy).
/// When `explicitToolPolicy` is nil, no routing-level tool/skill policy is applied.
public struct ConversationRoutingPrefs: Codable, Sendable, Equatable {
    public var preferredModelID: UUID?
    public var preferredSlug: String?
    /// Optional opaque JSON for future ModelQuery embedding.
    public var queryJSON: String?
    public var modelOptions: ConversationRoutingModelOptions?
    public var explicitToolPolicy: ConversationExplicitToolPolicy?

    public init(
        preferredModelID: UUID? = nil,
        preferredSlug: String? = nil,
        queryJSON: String? = nil,
        modelOptions: ConversationRoutingModelOptions? = nil,
        explicitToolPolicy: ConversationExplicitToolPolicy? = nil
    ) {
        self.preferredModelID = preferredModelID
        self.preferredSlug = preferredSlug
        self.queryJSON = queryJSON
        self.modelOptions = modelOptions
        self.explicitToolPolicy = explicitToolPolicy
    }
}

public enum ConversationExplicitToolPolicy: Codable, Sendable, Equatable {
    case denylist(tools: [String], skills: [String])
    case allowlist(tools: [String], skills: [String])

    private enum CodingKeys: String, CodingKey {
        case kind, tools, skills
    }

    private enum Kind: String, Codable {
        case denylist
        case allowlist
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let rawTools = try c.decode([String].self, forKey: .tools)
        let tools = ToolRegistryNameIndex.builtIn.normalizedPolicyList(rawTools)
        let skills = try c.decode([String].self, forKey: .skills)
        switch kind {
        case .denylist: self = .denylist(tools: tools, skills: skills)
        case .allowlist: self = .allowlist(tools: tools, skills: skills)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .denylist(let tools, let skills):
            try c.encode(Kind.denylist, forKey: .kind)
            try c.encode(tools, forKey: .tools)
            try c.encode(skills, forKey: .skills)
        case .allowlist(let tools, let skills):
            try c.encode(Kind.allowlist, forKey: .kind)
            try c.encode(tools, forKey: .tools)
            try c.encode(skills, forKey: .skills)
        }
    }
}

// MARK: - Budget snapshot (durable hints)

/// Durable snapshot fields aligned with wire ``ConversationContextBudget`` / spend signals where persisted.
public struct ConversationBudgetSnapshot: Codable, Sendable, Equatable {
    public var maxUSD: Double?
    public var spentUSD: Double?
    public var contextBudgetRemainingTokens: Int?

    public init(maxUSD: Double? = nil, spentUSD: Double? = nil, contextBudgetRemainingTokens: Int? = nil) {
        self.maxUSD = maxUSD
        self.spentUSD = spentUSD
        self.contextBudgetRemainingTokens = contextBudgetRemainingTokens
    }
}

// MARK: - Branch index

public struct ConversationBranchRef: Codable, Sendable, Equatable, Hashable {
    public var childConversationID: UUID
    public var branchedAtMessageID: UUID

    public init(childConversationID: UUID, branchedAtMessageID: UUID) {
        self.childConversationID = childConversationID
        self.branchedAtMessageID = branchedAtMessageID
    }
}

// MARK: - Attachment descriptors (catalog)

public enum ConversationAttachmentAddedBy: String, Codable, Sendable {
    case user
    case agent
}

public struct ConversationAttachmentDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Content-addressed blob id (sha256 hex) when bytes live in the session blob store.
    public var blobId: String?
    public var kind: String
    public var name: String
    public var mimeType: String?
    public var byteSize: Int64?
    public var addedAt: Date?
    public var addedBy: ConversationAttachmentAddedBy?
    /// Raw trust class string for forward-compatible storage/wire semantics.
    public var trustRaw: String?
    /// Typed trust helper for known classes (`nil` for unknown or missing raw values).
    public var typedTrust: AttachmentInputTrust? {
        get { AttachmentInputTrustCodec.typedTrust(from: trustRaw) }
        set { trustRaw = newValue?.rawValue }
    }

    public init(
        id: UUID,
        blobId: String? = nil,
        kind: String,
        name: String,
        mimeType: String? = nil,
        byteSize: Int64? = nil,
        addedAt: Date? = nil,
        addedBy: ConversationAttachmentAddedBy? = nil,
        trustRaw: String? = nil
    ) {
        self.id = id
        self.blobId = blobId?.lowercased()
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.addedAt = addedAt
        self.addedBy = addedBy
        self.trustRaw = AttachmentInputTrustCodec.sanitizedInputTrustRaw(trustRaw)
    }
}

// MARK: - Attachment projection policy artifacts

public enum ConversationAttachmentProjectionDisposition: String, Codable, Sendable, CaseIterable {
    case inline
    case summarize
    case searchOnly = "search_only"
}

public struct ConversationAttachmentProjectionDecision: Codable, Sendable, Equatable {
    public var attachmentID: UUID
    public var attachmentName: String
    public var attachmentKind: String
    public var disposition: ConversationAttachmentProjectionDisposition
    public var reason: String

    public init(
        attachmentID: UUID,
        attachmentName: String,
        attachmentKind: String,
        disposition: ConversationAttachmentProjectionDisposition,
        reason: String
    ) {
        self.attachmentID = attachmentID
        self.attachmentName = attachmentName
        self.attachmentKind = attachmentKind
        self.disposition = disposition
        self.reason = reason
    }
}

// MARK: - JSON helpers (persistence layer)

public enum ConversationResourceJSON {
    public static func encodeTags(_ tags: [String]) -> String? {
        guard !tags.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(tags),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func decodeTags(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return tags
    }

    public static func encodeBranchRefs(_ refs: [ConversationBranchRef]) -> String? {
        guard !refs.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(refs),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func decodeBranchRefs(_ json: String?) -> [ConversationBranchRef] {
        guard let json, let data = json.data(using: .utf8),
              let refs = try? JSONDecoder().decode([ConversationBranchRef].self, from: data) else {
            return []
        }
        return refs
    }

    public static func encodeAttachments(_ items: [ConversationAttachmentDescriptor]) -> String? {
        guard !items.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(items),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func decodeAttachments(_ json: String?) -> [ConversationAttachmentDescriptor] {
        guard let json, let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([ConversationAttachmentDescriptor].self, from: data) else {
            return []
        }
        return items
    }

    public static func encodeRoutingPrefs(_ prefs: ConversationRoutingPrefs) -> String? {
        if prefs.preferredModelID == nil,
           prefs.preferredSlug == nil,
           prefs.queryJSON == nil,
           prefs.modelOptions == nil,
           prefs.explicitToolPolicy == nil {
            return nil
        }
        guard let data = try? JSONEncoder().encode(prefs),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func decodeRoutingPrefs(_ json: String?) -> ConversationRoutingPrefs? {
        guard let json, let data = json.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(ConversationRoutingPrefs.self, from: data) else {
            return nil
        }
        return prefs
    }

    public static func encodeBudgetSnapshot(_ snap: ConversationBudgetSnapshot) -> String? {
        guard snap.maxUSD != nil || snap.spentUSD != nil || snap.contextBudgetRemainingTokens != nil else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(snap),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func decodeBudgetSnapshot(_ json: String?) -> ConversationBudgetSnapshot? {
        guard let json, let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(ConversationBudgetSnapshot.self, from: data) else {
            return nil
        }
        return snap
    }
}
