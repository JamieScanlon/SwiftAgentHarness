//
//  Harness-aligned persistence value types and errors (see Documentation/HARNESS_PERSISTENCE_REFERENCE.md).
//

import EasyJSON
import Foundation
import SwiftAgentKit

// MARK: - Entry ID

/// Canonical transcript row key at the SessionBackend boundary (8-char lowercase hex).
public struct SessionEntryID: RawRepresentable, Codable, Hashable, Sendable, LosslessStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(_ description: String) {
        guard let normalized = Self.normalize(description) else { return nil }
        self.rawValue = normalized
    }

    public static func generate() -> SessionEntryID {
        let value = UInt32.random(in: UInt32.min...UInt32.max)
        return SessionEntryID(rawValue: String(format: "%08x", value))
    }

    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isShortHex(trimmed) else { return nil }
        return trimmed
    }

    static func isShortHex(_ value: String) -> Bool {
        guard value.count == 8 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

// MARK: - Errors

enum SessionPersistenceError: Error, Equatable, Sendable {
    case conversationNotFound(UUID)
    case entryNotFound(conversationID: UUID, entryId: SessionEntryID)
    case lockTimeout(conversationID: UUID, waitedMs: Int)
    /// README `LockStale(holder_pid)` — recoverable; `detail` may note watchdog / reap.
    case lockStale(conversationId: UUID, holderPid: Int32?, detail: String)
    case lockNotHeld(conversationId: UUID)
    /// README `IdempotencyHit` — same idempotency key reused with a conflicting append (e.g. different payload or job id).
    case idempotencyHit(idempotencyKey: String, existingRunId: UUID)
    case controlPlaneRevisionConflict(conversationID: UUID, expectedRevision: UInt64, actualRevision: UInt64?)
    /// README `resolve_by_title`: more than one catalog row shares the same case-sensitive ``title`` (and lifecycle filter when set).
    case titleAmbiguous(title: String, lifecycleState: String?)
    /// Duplicate non-null ``(agent_id, title)`` would violate the v2 partial unique index (insert/update title collision).
    case duplicateCatalogTitle(reason: String)
    /// Client tail cursor is farther behind than the configured transcript replay window allows (see ``TranscriptTailRetentionPolicy``).
    case retentionExceeded(conversationID: UUID, clientFloorSequence: Int, latestSequence: Int, maxAllowedLag: Int)
    /// v2 SQLite catalog could not complete an operation after retries (busy / locked).
    case catalogBusy
    /// v2 catalog (or auxiliary SQLite) I/O failures — **`sqliteCode`** is `sqlite3_extended_errcode` when from SQLite; no raw `errmsg` text on the surface.
    case catalogStoreFailed(operation: String, sqliteCode: Int32?)
    /// Catalog on disk was produced by a newer binary than this build (`foundCatalogVersion` > `supportedCatalogVersion`).
    case schemaUpgradeRequired(foundCatalogVersion: Int, supportedCatalogVersion: Int)
    /// Catalog preflight or integrity check failed (e.g. duplicate titles before schema v6).
    case catalogIntegrityFailed(reason: String)
    /// Transcript payload failed structured validation (allowlisted Codable shapes).
    case transcriptPayloadInvalid(reason: String)
    /// Internal / staged surface not wired yet, or auxiliary store failure message.
    case unsupportedOperation(String)
    case blobNotFound(blobId: String)
    case blobExpired(blobId: String, expiredAt: Date)
    case blobTooLarge(size: Int, maxBytes: Int)
    /// Catalog or transcript references this durable blob id but bytes are absent on disk (corruption).
    case durableBlobMissing(blobId: String, conversationID: UUID?)
    case transcriptCorrupt(conversationID: UUID, reason: String)
    case transcriptQuarantined(conversationID: UUID, reason: String)
}

enum SessionBlobReferenceSource: String, Sendable, Equatable {
    case messageAttachmentRefs
    case messagePayload
    case attachmentsCatalog
}

struct SessionCollectedBlobReference: Sendable, Equatable, Hashable {
    var blobId: String
    var conversationID: UUID
    var messageSequence: Int?
    var source: SessionBlobReferenceSource
}

struct SessionDanglingBlobReference: Sendable, Equatable {
    var blobId: String
    var conversationID: UUID
    var messageSequence: Int?
    var source: SessionBlobReferenceSource
}

enum SessionBlobIntegritySeverity: String, Sendable, Equatable {
    case normal
    case elevated
    case storeAbsentSuspected
}

struct SessionBlobIntegrityReport: Sendable, Equatable {
    var referencedCount: Int
    var danglingCount: Int
    var danglingRatio: Double
    var severity: SessionBlobIntegritySeverity
    var danglingSamples: [SessionDanglingBlobReference]
    var trashedUnreferencedCount: Int
    var hardDeletedTrashCount: Int
}

enum TranscriptDamageClass: String, Sendable, Equatable, Codable {
    case clean
    case tailConfined
    case structural
    case missingFile
}

enum TranscriptMaintenanceAction: String, Sendable, Equatable {
    case none
    case autoRepaired
    case quarantined
    case verifyFailed
}

struct TranscriptVerifyReport: Sendable, Equatable {
    var conversationID: UUID
    var catalogLatestSequence: Int
    var lastCleanJSONLSequence: Int
    var isTailConfined: Bool
    var isLosslesslyRepairable: Bool
    var damageClass: TranscriptDamageClass
    var reason: String?
    var maintenanceAction: TranscriptMaintenanceAction
}

enum SessionTranscriptIntegrityState: String, Codable, Sendable {
    case ok
    case quarantined
}

struct SessionTranscriptIntegrity: Sendable, Equatable, Codable {
    var state: SessionTranscriptIntegrityState
    var reason: String?
}

enum SessionTranscriptIntegritySeverity: String, Sendable, Equatable {
    case normal
    case elevated
    case storeAbsentSuspected
}

struct SessionTranscriptIntegrityReport: Sendable, Equatable {
    var conversationCount: Int
    var autoRepairedCount: Int
    var quarantinedCount: Int
    var verifyFailedCount: Int
    var severity: SessionTranscriptIntegritySeverity
    var samples: [TranscriptVerifyReport]
}

// MARK: - List / search

struct SessionCatalogPage: Sendable, Equatable {
    var records: [SessionCatalogRecord]
    /// Opaque keyset cursor shared by catalog page and README `list_conversations` filtered page.
    /// Contract: `"<updatedAt.timeIntervalSince1970>|<id.uuidString>"` where ordering is
    /// `updatedAt DESC, id DESC`. Invalid cursor payloads are treated as first-page reads.
    var nextCursor: String?
}

/// README `list_conversations` filter bundle (cursor matches ``SessionCatalogPage.nextCursor``).
struct SessionConversationListFilter: Sendable, Equatable {
    var agentId: String?
    var source: String?
    var cwd: String?
    /// Harness lifecycle string (e.g. `ConversationLifecycleState.rawValue`).
    var lifecycleState: String?
    /// Inclusive lower bound on catalog **`updated_at`** (README `since` as time maps here).
    var since: Date?
    var parentConversationID: UUID?
    var catalogVisibility: ConversationCatalogVisibilityFilter = .primaryOnly
}

enum SessionCatalogKeysetCursor {
    static func decode(_ cursor: String?) -> (updatedAtUnixSeconds: Double, idString: String)? {
        guard let cursor, !cursor.isEmpty else { return nil }
        let parts = cursor.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let ts = Double(parts[0]),
              !parts[1].isEmpty else {
            return nil
        }
        return (updatedAtUnixSeconds: ts, idString: String(parts[1]))
    }

    static func encode(updatedAt: Date, id: UUID) -> String {
        "\(updatedAt.timeIntervalSince1970)|\(id.uuidString)"
    }
}

enum SessionPatchValue<T: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(T)
}

enum SessionNullablePatchValue<T: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(T?)
}

/// README `update_conversation` patch payload for catalog-owned fields.
struct SessionConversationUpdatePatch: Sendable, Equatable {
    var topic: SessionNullablePatchValue<String> = .unchanged
    var description: SessionNullablePatchValue<String> = .unchanged
    var modelName: SessionPatchValue<String> = .unchanged
    var interactionModeRaw: SessionPatchValue<String> = .unchanged
    var modeProfileID: SessionNullablePatchValue<String> = .unchanged
    var source: SessionNullablePatchValue<String> = .unchanged
    var trustClass: SessionNullablePatchValue<String> = .unchanged
    var parentConversationID: SessionNullablePatchValue<UUID> = .unchanged
    var forkAnchorEntryID: SessionNullablePatchValue<SessionEntryID> = .unchanged
    var headEntryId: SessionNullablePatchValue<SessionEntryID> = .unchanged
    var userID: SessionNullablePatchValue<String> = .unchanged
    var lifecycleStateRaw: SessionNullablePatchValue<String> = .unchanged
    var title: SessionNullablePatchValue<String> = .unchanged
    var cwd: SessionNullablePatchValue<String> = .unchanged
    var endedAt: SessionNullablePatchValue<Date> = .unchanged
    var endReason: SessionNullablePatchValue<String> = .unchanged
    var toolCallCount: SessionNullablePatchValue<Int> = .unchanged
    var totalPromptTokens: SessionNullablePatchValue<Int> = .unchanged
    var totalCompletionTokens: SessionNullablePatchValue<Int> = .unchanged
    var totalCostMinorUnits: SessionNullablePatchValue<Int> = .unchanged
    var modelConfigJSON: SessionNullablePatchValue<String> = .unchanged
    var reasoningTokens: SessionNullablePatchValue<Int> = .unchanged
    var cacheTokens: SessionNullablePatchValue<Int> = .unchanged
    var firstUserPrompt: SessionNullablePatchValue<String> = .unchanged
    var updatedAt: SessionPatchValue<Date> = .unchanged
    var resourceJSON: SessionNullablePatchValue<String> = .unchanged
    var currentRunID: SessionNullablePatchValue<UUID> = .unchanged
    var lastActiveAt: SessionNullablePatchValue<Date> = .unchanged
    var resourceRunStatusRaw: SessionNullablePatchValue<String> = .unchanged
    var metadataJSON: SessionNullablePatchValue<String> = .unchanged
    var systemPrompt: SessionNullablePatchValue<String> = .unchanged
    var lineageKind: SessionPatchValue<ConversationLineageKind> = .unchanged
    var origin: SessionPatchValue<ConversationOrigin> = .unchanged
}

extension SessionConversationListFilter {
    /// Applies README filter dimensions to one catalog row (used by in-memory filtered list paths).
    func matches(record: SessionCatalogRecord) -> Bool {
        if let aid = agentId, aid != record.agentId { return false }
        if let s = source {
            if record.source != s { return false }
        }
        if let c = cwd {
            if record.cwd != c { return false }
        }
        if let l = lifecycleState {
            if record.lifecycleStateRaw != l { return false }
        }
        if let since {
            if record.updatedAt < since { return false }
        }
        if let parentID = parentConversationID {
            if record.parentConversationID != parentID { return false }
        }
        if !ConversationCatalogVisibility.matchesFilter(
            lineage: record.lineageKind,
            origin: record.origin,
            filter: catalogVisibility
        ) {
            return false
        }
        return true
    }
}

/// README `create_conversation` inputs (backend assigns conversation ``UUID``).
struct SessionConversationCreationParams: Sendable, Equatable {
    var agentId: String
    var source: String
    var trustClass: String?
    var parentConversationID: UUID?
    var forkAnchorMessageID: UUID?
    var cwd: String?
    var modelName: String
    var interactionModeRaw: String
    var modeProfileID: String?
    var title: String?
    var topic: String?
    var description: String?
    var userID: String?
    var lifecycleStateRaw: String?
    var modelConfigJSON: String?
    var createdAt: Date
    var lineageKind: ConversationLineageKind = .root
    var origin: ConversationOrigin = .user
}

extension SessionConversationCreationParams {
    /// Canonical create contract checks for SessionBackend create_conversation parity.
    /// Required: `agentId`, `source`; `trustClass` defaults to `"user"` when omitted.
    func normalizedForCreate() throws -> SessionConversationCreationParams {
        var out = self
        out.agentId = out.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        out.source = out.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.agentId.isEmpty {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "create_conversation requires non-empty agentId")
        }
        if out.source.isEmpty {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "create_conversation requires non-empty source")
        }
        let trust = out.trustClass?.trimmingCharacters(in: .whitespacesAndNewlines)
        out.trustClass = (trust?.isEmpty == false) ? trust : "user"
        let lifecycle = out.lifecycleStateRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        out.lifecycleStateRaw = (lifecycle?.isEmpty == false) ? lifecycle : ConversationLifecycleState.active.rawValue
        if out.interactionModeRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.interactionModeRaw = InteractionMode.agent.rawValue
        }
        if let title = out.title {
            let normalized = SessionTitleResolution.sanitizedTitle(title)
            out.title = normalized.isEmpty ? nil : normalized
        }
        if let topic = out.topic {
            let normalized = SessionTitleResolution.sanitizedTitle(topic)
            out.topic = normalized.isEmpty ? nil : normalized
        }
        return out
    }

    func makeCatalogRecord(id: UUID, catalogAgentId: String, updatedAt: Date) -> SessionCatalogRecord {
        SessionCatalogRecord(
            id: id,
            topic: topic ?? title,
            description: description,
            messageCount: 0,
            updatedAt: updatedAt,
            createdAt: createdAt,
            modelName: modelName,
            interactionModeRaw: interactionModeRaw,
            modeProfileID: modeProfileID,
            source: source,
            trustClass: trustClass,
            parentConversationID: parentConversationID,
            forkAnchorEntryID: forkAnchorMessageID.map(SessionEntryID.fromMessageUUID),
            userID: userID,
            lifecycleStateRaw: lifecycleStateRaw ?? ConversationLifecycleState.active.rawValue,
            title: title ?? topic,
            cwd: cwd,
            endedAt: nil,
            endReason: nil,
            toolCallCount: nil,
            totalPromptTokens: nil,
            totalCompletionTokens: nil,
            totalCostMinorUnits: nil,
            modelConfigJSON: modelConfigJSON,
            reasoningTokens: nil,
            cacheTokens: nil,
            controlPlaneRevision: 0,
            firstUserPrompt: nil,
            agentId: catalogAgentId,
            lineageKind: lineageKind,
            origin: origin
        )
    }
}

extension SessionCatalogRecord {
    /// Canonical fork child-row normalization for README `fork_conversation`.
    /// Keeps parent defaults, then applies lineage and child-specific reset fields.
    func normalizedForkChildRecord(
        newConversationID: UUID,
        parentConversationID: UUID,
        forkAnchorEntryID: SessionEntryID,
        requestedTitle: String?,
        catalogAgentID: String,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil,
        now: Date = Date()
    ) -> SessionCatalogRecord {
        var child = self
        child.id = newConversationID
        child.parentConversationID = parentConversationID
        child.forkAnchorEntryID = forkAnchorEntryID
        child.lineageKind = childLineageKind
        child.origin = childOrigin ?? origin
        child.messageCount = 0
        let normalizedTitleRaw = requestedTitle.map(SessionTitleResolution.sanitizedTitle)
        if let normalizedTitleRaw, !normalizedTitleRaw.isEmpty {
            child.title = normalizedTitleRaw
            child.topic = normalizedTitleRaw
        }
        child.createdAt = now
        child.updatedAt = now
        child.firstUserPrompt = nil
        child.agentId = catalogAgentID
        return child
    }
}

struct SessionMessageSearchHit: Sendable, Equatable {
    var conversationID: UUID
    var entryId: SessionEntryID
    var sequence: Int
    /// FTS5 `snippet()` excerpt with highlight markers (see ``SessionFTS5SearchConstants``).
    var snippet: String
    /// Raw SQLite `bm25(messages_fts)`; **lower is more relevant** (README `MessageHit.score` is float; direction documented here).
    var score: Double
    var timestamp: Date
}

/// Shared FTS5 `snippet()` delimiters; in-memory search uses the same markers via ``SessionMessageSearchSubstringFallback``.
enum SessionFTS5SearchConstants: Sendable {
    static let snippetHighlightStart = "<b>"
    static let snippetHighlightEnd = "</b>"
    static let snippetEllipsis = "…"
    static let snippetTokenCount = 16
}

// MARK: - Catalog (harness `conversations` row projection)

struct SessionCatalogRecord: Sendable, Equatable {
    var id: UUID
    var topic: String?
    var description: String?
    var messageCount: Int
    var updatedAt: Date
    var createdAt: Date
    var modelName: String
    var interactionModeRaw: String
    var modeProfileID: String?

    // P1 harness-aligned columns (sparse until populated by create/update paths)
    var source: String?
    var trustClass: String?
    var parentConversationID: UUID?
    var forkAnchorEntryID: SessionEntryID?
    /// Active transcript leaf (README `head_entry_id`); `readLineage` walks parent chain root → this id.
    var headEntryId: SessionEntryID?
    /// Harness resource blob (tags, routing, budget, branches, attachments, metadata, system prompt).
    var resourceJSON: String? = nil
    var currentRunID: UUID? = nil
    var lastActiveAt: Date? = nil
    var resourceRunStatusRaw: String? = nil
    var metadataJSON: String? = nil
    var systemPrompt: String? = nil
    var userID: String?
    /// Harness/catalog lifecycle string (e.g. `ConversationLifecycleState.rawValue`).
    var lifecycleStateRaw: String?
    var title: String?
    var cwd: String?
    var endedAt: Date?
    var endReason: String?
    var toolCallCount: Int?
    var totalPromptTokens: Int?
    var totalCompletionTokens: Int?
    /// Minor units / fixed-point — harness README cost rollup; USD cents if populated from `budgetSnapshot`.
    var totalCostMinorUnits: Int?
    var modelConfigJSON: String?
    var reasoningTokens: Int?
    var cacheTokens: Int?
    /// Optimistic concurrency for control-plane catalog mutations (v2 SQLite `control_plane_revision`); mirrored on ``ModelConversation/controlPlaneRevision`` at runtime.
    var controlPlaneRevision: Int
    var firstUserPrompt: String?
    /// Owning harness agent for v2 transcript paths + catalog scoping (see `SAH_SESSION_AGENT_ID`).
    var agentId: String
    /// Boot/periodic verify quarantine state; nil means ok.
    var transcriptIntegrity: SessionTranscriptIntegrity? = nil
    var lineageKind: ConversationLineageKind = .root
    var origin: ConversationOrigin = .user

    /// REST list + sidebar label: persisted title, topic, then truncated ``firstUserPrompt``.
    func listDisplayTopic(prefixLength: Int = 30) -> String? {
        Self.listDisplayTopic(
            title: title,
            topic: topic,
            firstUserPrompt: firstUserPrompt,
            prefixLength: prefixLength
        )
    }

    static func listDisplayTopic(
        title: String?,
        topic: String?,
        firstUserPrompt: String?,
        prefixLength: Int = 30
    ) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
        if let resolved = nonEmpty(title) ?? nonEmpty(topic) {
            return resolved.count <= prefixLength
                ? resolved
                : "\(resolved.prefix(prefixLength))..."
        }
        guard let prompt = nonEmpty(firstUserPrompt) else { return nil }
        return prompt.count <= prefixLength ? prompt : "\(prompt.prefix(prefixLength))..."
    }
}

/// One durable task/cron enqueue record (JSONL line under `cron/runs/` + row in `harness_tasks`).
public struct SessionHarnessTaskRunRecord: Sendable, Equatable, Codable {
    public var runId: UUID
    public var jobId: String
    public var createdAt: Date
    /// Opaque job payload (encoded as base64 in JSONL).
    public var payload: Data
    public var idempotencyKey: String?

    enum CodingKeys: String, CodingKey {
        case runId
        case jobId
        case createdAt
        case payloadBase64
        case idempotencyKey
    }

    public init(runId: UUID, jobId: String, createdAt: Date, payload: Data, idempotencyKey: String?) {
        self.runId = runId
        self.jobId = jobId
        self.createdAt = createdAt
        self.payload = payload
        self.idempotencyKey = idempotencyKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(UUID.self, forKey: .runId)
        jobId = try c.decode(String.self, forKey: .jobId)
        createdAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .createdAt))
        let b64 = try c.decode(String.self, forKey: .payloadBase64)
        payload = Data(base64Encoded: b64) ?? Data()
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(jobId, forKey: .jobId)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encode(payload.base64EncodedString(), forKey: .payloadBase64)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }
}

/// README catalog `tasks` row + `upsert_task` / `list_tasks` wire shape (JSON in ``HarnessSessionPersistence/upsertScheduledTaskDefinition``).
struct SessionScheduledTaskDefinitionRecord: Codable, Sendable, Equatable {
    var taskId: String
    var agentId: String?
    /// Opaque JSON body (schedule, labels, extensions, etc.).
    var definitionJSON: String
}

// MARK: - Transcript entries (opaque payload; tree fields for v2 JSONL)

struct SessionTranscriptEntry: Sendable, Equatable {
    /// Monotonic per conversation (allocated under transcript write lock; formerly message-array index + 1).
    var sequence: Int
    var entryId: SessionEntryID
    var parentEntryId: SessionEntryID?
    var type: SessionTranscriptEntryType
    /// When `type` is `.custom` or unknown on read, preserves the on-wire harness type string.
    var harnessTypeRaw: String? = nil
    var timestamp: Date
    /// Opaque JSON at the SessionBackend boundary; message/system rows encode ``MessageTranscriptPayload``, other types use harness payloads.
    var payloadJSON: String

    /// Stored in SQLite `messages.role` / JSONL `type` (harness string).
    var persistedTypeRaw: String {
        harnessTypeRaw ?? type.rawValue
    }
}

enum SessionTranscriptEntryType: String, Sendable, Codable {
    case message
    case system
    case compaction
    case branchSummary = "branch_summary"
    case custom
    case modelChange = "model_change"
    case thinkingLevelChange = "thinking_level_change"
    /// Gap 6: raw journal (`message_appended`, `interaction_mode_changed`) in v2 transcript only.
    case conversationJournal = "conversation_journal"
    /// Gap 6: derived journal (`CachedConversationEvent` kinds) in v2 transcript only.
    case derivedJournal = "derived_journal"
}

extension SessionCatalogRecord {
    init(modelConversation: ModelConversation) {
        let budget = modelConversation.budgetSnapshot
        let costMinor: Int?
        if let spent = budget?.spentUSD {
            costMinor = Int((spent * 100.0).rounded())
        } else {
            costMinor = nil
        }
        self.init(
            id: modelConversation.id,
            topic: modelConversation.topic,
            description: modelConversation.description,
            messageCount: modelConversation.messages.count,
            updatedAt: modelConversation.updatedAt,
            createdAt: modelConversation.createdAt,
            modelName: modelConversation.model.modelName,
            interactionModeRaw: modelConversation.interactionMode.rawValue,
            modeProfileID: modelConversation.modeProfileID,
            source: modelConversation.harnessPersistenceSource ?? "swiftdata",
            trustClass: modelConversation.harnessPersistenceTrustClass,
            parentConversationID: modelConversation.parentConversationID ?? modelConversation.splitFromConversationID,
            forkAnchorEntryID: modelConversation.splitThreadAfterMessageID.map(SessionEntryID.fromMessageUUID),
            headEntryId: nil,
            resourceJSON: SessionCatalogResourceCodec.encode(modelConversation),
            currentRunID: modelConversation.currentRunID,
            lastActiveAt: modelConversation.lastActiveAt ?? modelConversation.updatedAt,
            resourceRunStatusRaw: modelConversation.resourceRunStatus.rawValue,
            metadataJSON: Self.metadataJSONString(from: modelConversation.metadata),
            systemPrompt: modelConversation.systemPrompt.isEmpty ? nil : modelConversation.systemPrompt,
            userID: modelConversation.ownerAccountID?.uuidString,
            lifecycleStateRaw: modelConversation.lifecycle.rawValue,
            title: modelConversation.topic,
            cwd: modelConversation.harnessPersistenceCwd,
            endedAt: modelConversation.lifecycle == .archived ? modelConversation.lastActiveAt : nil,
            endReason: nil,
            toolCallCount: nil,
            totalPromptTokens: nil,
            totalCompletionTokens: nil,
            totalCostMinorUnits: costMinor,
            modelConfigJSON: SessionCatalogResourceCodec.modelConfigJSONHint(from: modelConversation),
            reasoningTokens: nil,
            cacheTokens: nil,
            controlPlaneRevision: Int(clamping: modelConversation.controlPlaneRevision),
            firstUserPrompt: modelConversation.messages.first(where: { $0.role == .user })?.content,
            agentId: modelConversation.harnessPersistenceAgentId ?? SessionPersistenceLayout.defaultAgentId,
            lineageKind: modelConversation.lineageKind,
            origin: modelConversation.origin
        )
    }

    static func metadataJSONString(from metadata: JSON?) -> String? {
        guard let metadata,
              let data = try? JSONEncoder().encode(metadata),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func encodeModelConfigHint(_ conversation: ModelConversation) -> String? {
        SessionCatalogResourceCodec.modelConfigJSONHint(from: conversation)
    }

    /// Minimal row for tests and bootstrap before P1 fields are relevant.
    init(
        id: UUID,
        topic: String?,
        description: String?,
        messageCount: Int,
        updatedAt: Date,
        createdAt: Date,
        modelName: String,
        interactionModeRaw: String,
        modeProfileID: String? = nil
    ) {
        self.init(
            id: id,
            topic: topic,
            description: description,
            messageCount: messageCount,
            updatedAt: updatedAt,
            createdAt: createdAt,
            modelName: modelName,
            interactionModeRaw: interactionModeRaw,
            modeProfileID: modeProfileID,
            source: nil,
            trustClass: nil,
            parentConversationID: nil,
            forkAnchorEntryID: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            title: topic,
            cwd: nil,
            endedAt: nil,
            endReason: nil,
            toolCallCount: nil,
            totalPromptTokens: nil,
            totalCompletionTokens: nil,
            totalCostMinorUnits: nil,
            modelConfigJSON: nil,
            reasoningTokens: nil,
            cacheTokens: nil,
            controlPlaneRevision: 0,
            firstUserPrompt: nil,
            agentId: SessionPersistenceLayout.defaultAgentId
        )
    }
}

extension SessionTranscriptEntryType {
    /// Decode harness/JSONL type string; accepts pre-harness `branchSummary` spelling.
    static func decoding(from raw: String) -> SessionTranscriptEntryType {
        decoding(from: raw, transcriptHeaderVersion: SessionJSONLTranscriptFormat.maxSupportedHeaderVersion)
    }

    /// Decode with optional header-aware normalization (JSONL); SQLite mirrors use the same strings without header context.
    static func decoding(from raw: String, transcriptHeaderVersion: Int) -> SessionTranscriptEntryType {
        _ = transcriptHeaderVersion // reserved for pi-mono / future header-version-specific aliases
        if let v = Self(rawValue: raw) { return v }
        if raw == "branchSummary" { return .branchSummary }
        return .custom
    }

    /// When true, appending this row bumps `conversations.message_count` (chat-shaped transcript only).
    var countsTowardSessionCatalogMessageTotal: Bool {
        switch self {
        case .message, .system, .modelChange, .thinkingLevelChange, .custom:
            return true
        case .compaction, .branchSummary, .conversationJournal, .derivedJournal:
            return false
        }
    }
}
