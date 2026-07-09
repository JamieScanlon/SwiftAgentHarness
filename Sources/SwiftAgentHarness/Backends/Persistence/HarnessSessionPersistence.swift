//
//  Combined catalog + transcript seam with transcript write lock (harness SessionBackend subset).
//  Single-process servers: writers are serialized via ConversationPersistenceDomain (actor).
//  File-based locks apply when multiple OS processes share SAH_SESSION_STORE_ROOT (X4).
//

import Foundation

protocol HarnessSessionPersistence: CatalogPersistence, TranscriptPersistence {
    /// Process-aware file lock for ``LocalHarnessSessionPersistence``; in-process lock for ``InMemoryHarnessSessionPersistence``.
    /// - Parameters:
    ///   - timeoutMs: README default 30_000; ignored for in-memory backend beyond setting ``TranscriptWriteLock/acquiredAt``.
    func acquireTranscriptWriteLock(conversationID: UUID, allowReentrant: Bool, timeoutMs: Int) throws -> any TranscriptWriteLock

    /// Next sequence for a v2 conversation; valid only under the transcript write lock.
    func nextTranscriptSequence(conversationID: UUID) throws -> Int

    /// Append one row while the caller holds the transcript write lock.
    /// `entry.sequence` must come from `nextTranscriptSequence` in the same critical section.
    func appendMirroredTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws

    /// Best-effort undo when the given entry is still the transcript tail.
    func rollBackLastMirroredTranscriptAppend(conversationID: UUID, entry: SessionTranscriptEntry) throws

    // MARK: - P1 SessionBackend-shaped API

    func applyConversationLifecycle(conversationID: UUID, lifecycle: ConversationLifecycleState) throws

    func endConversation(conversationID: UUID, reason: String?) throws

    /// Hard-delete catalog row, transcript index, and on-disk transcript for the conversation.
    func removeSessionConversation(conversationID: UUID) throws

    func reopenConversation(conversationID: UUID) throws

    func applyConversationTitle(conversationID: UUID, title: String, expectedControlPlaneRevision: UInt64) throws

    func transcriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry

    func childTranscriptEntries(conversationID: UUID, parentEntryId: SessionEntryID) throws -> [SessionTranscriptEntry]

    func transcriptLineage(conversationID: UUID, entryId: SessionEntryID, maxDepth: Int) throws -> [SessionTranscriptEntry]

    /// README `read_lineage`: parent chain **root → leaf** for the active branch ending at `leafEntryId`.
    func readLineage(conversationID: UUID, leafEntryId: SessionEntryID) throws -> [SessionTranscriptEntry]

    /// Catalog `head_entry_id` for the conversation's active branch tip.
    func activeHeadEntryId(conversationID: UUID) throws -> SessionEntryID?

    /// Rewinds the active branch to `entryId` (must exist and be an ancestor of the current head, inclusive).
    func setActiveHeadEntryId(conversationID: UUID, entryId: SessionEntryID, expectedRevision: UInt64?) throws -> SessionCatalogRecord

    func appendTranscriptEntries(conversationID: UUID, entries: [SessionTranscriptEntry]) throws

    /// README `fork_conversation`: validates parent+anchor, creates child catalog row with lineage fields, and copies transcript prefix through `atEntryId` (inclusive).
    func forkConversation(
        parentConversationID: UUID,
        atEntryId: SessionEntryID,
        newConversationId: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind,
        childOrigin: ConversationOrigin?
    ) throws -> SessionCatalogRecord

    func childConversations(parentConversationID: UUID) throws -> [SessionCatalogRecord]

    func recordTranscriptCompactionEntry(conversationID: UUID, payloadJSON: String) throws -> Int

    func recordTranscriptBranchSummaryEntry(conversationID: UUID, payloadJSON: String) throws -> Int

    /// runs.md lifecycle markers (`run_cancelled`, `run_orphaned`, …) as `custom` transcript rows.
    func appendRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws

    /// README `search_messages`: **`query`** is user/search text; persistence applies ``FTS5QuerySanitizer`` before SQLite ``MATCH`` (single sanitization boundary).
    func searchTranscriptMessages(query: String, agentId: String?, conversationID: UUID?, limit: Int) throws -> [SessionMessageSearchHit]

    func firstUserPromptText(conversationID: UUID) throws -> String?

    /// TTL idempotency check using the harness install's ``SessionDedupeSQLiteStore`` when present; in-memory backend returns `true` every time.
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) throws -> Bool

    /// Read-only idempotency probe; returns `true` when an unexpired dedupe row exists.
    func dedupePeek(key: String) throws -> Bool

    // MARK: - P3 Engine artifact cache (regenerable; not transcript-authoritative)

    /// Opaque cache read from ``cache/engine-artifacts`` when local store is present; in-memory backend returns nil.
    func getEngineArtifact(conversationID: UUID, key: String) throws -> Data?

    /// Persists cache blob under conversation-scoped key (v2 only).
    func putEngineArtifact(conversationID: UUID, key: String, data: Data) throws

    /// Removes one key, or entire conversation cache directory when `key` is nil (v2 only).
    func evictEngineArtifacts(conversationID: UUID, key: String?) throws

    /// Lists opaque cache keys under ``SessionPersistenceLayout/engineArtifactsDirectory`` when the v2 artifact store is present.
    func listEngineArtifactKeys(conversationID: UUID) throws -> [String]

    // MARK: - Tool result spill (session-scoped; recoverable oversized output)

    /// Spill directory for one conversation when on-disk store supports spill; nil for unsupported backends.
    func toolResultSpillDirectory(conversationID: UUID) -> URL?

    /// Idempotent spill keyed by tool call id.
    func putToolResultSpillIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult?

    /// True when `path` resolves under the conversation's spill directory.
    func isAllowlistedToolResultSpillPath(_ path: String, conversationID: UUID) -> Bool

    // MARK: - Media / blob store

    func putBlob(
        data: Data,
        durability: SessionBlobDurability,
        originalName: String?,
        mimeType: String?,
        trust: String,
        ttlSeconds: Int?,
        lane: SessionBlobEphemeralLane
    ) throws -> SessionBlobRef

    func putBlobFromURL(
        url: URL,
        durability: SessionBlobDurability,
        trust: String,
        ttlSeconds: Int?,
        maxBytes: Int?,
        lane: SessionBlobEphemeralLane
    ) throws -> SessionBlobRef

    func getBlob(blobId: String) throws -> Data

    func statBlob(blobId: String) throws -> SessionBlobRef

    func blobPath(blobId: String) throws -> URL?

    func promoteBlob(blobId: String) throws -> SessionBlobRef

    /// Hard delete: removes durable or ephemeral bytes regardless of catalog references.
    /// Caller asserts purge intent (GDPR, admin, delete-everywhere). Ordinary attachment detach must not call this.
    func deleteBlob(blobId: String) throws

    func sweepExpiredBlobs() throws -> Int

    /// Soft-deletes unreferenced durable blobs to `media/.trash/`, then hard-deletes trash past retention.
    func reclaimUnreferencedDurableBlobs(liveBlobIds: Set<String>, trashRetentionSeconds: Int) throws -> SessionBlobReclaimCounts

    /// Opens a catalog-referenced durable blob; maps missing bytes to ``SessionPersistenceError/durableBlobMissing(blobId:conversationID:)``.
    func openReferencedDurableBlob(blobId: String, conversationID: UUID?) throws -> Data

    func verifyTranscript(conversationID: UUID) throws -> TranscriptVerifyReport

    func repairQuarantinedTranscript(conversationID: UUID) throws

    // MARK: - P3c Tasks + cron (catalog + `cron/runs/<jobId>.jsonl`)

    /// Enqueues a durable task run: SQLite pending row + JSONL audit line. Duplicate `idempotencyKey` returns the existing run id.
    func appendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) throws -> UUID

    /// Last persisted JSONL rows for `jobId` (up to `limit`, oldest of the tail window first).
    func tailTaskRuns(jobId: String, limit: Int) throws -> [SessionHarnessTaskRunRecord]

    /// Oldest still-pending row in SQLite for restart catch-up.
    func latestUndeliveredTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord?

    /// Marks a pending row delivered (no-op if not pending).
    func markTaskRunDelivered(runId: UUID) throws

    // MARK: - README SessionBackend (alignment stubs; see Documentation/SESSION_BACKEND_TRACEABILITY.md)

    /// README `create_conversation`: backend assigns id, initializes catalog defaults, and bootstraps empty transcript backing.
    func createConversation(_ params: SessionConversationCreationParams) throws -> SessionCatalogRecord

    /// README `update_conversation`: applies partial catalog updates and returns the updated conversation record.
    /// `expectedRevision` maps to backend CAS revision (catalog `control_plane_revision` / ``SessionCatalogRecord/controlPlaneRevision``).
    func updateSessionConversation(conversationID: UUID, patch: SessionConversationUpdatePatch, expectedRevision: UInt64?) throws -> SessionCatalogRecord

    /// README `list_conversations` with filters + keyset cursor (``SessionCatalogPage/nextCursor``).
    /// Ordering is `updated_at DESC, id DESC`; `since` maps to inclusive `updated_at >= since`.
    func listConversations(_ filter: SessionConversationListFilter, limit: Int, cursor: String?) throws -> SessionCatalogPage

    /// README `resolve_by_title`.
    func resolveSessionByTitle(_ title: String, lifecycleState: String?) throws -> UUID?

    /// README `next_title_in_lineage`.
    func nextSessionTitleInLineage(forTitle title: String, lifecycleState: String?) throws -> String?

    /// README `resolve_latest_in_lineage`: id of the newest lineage row for **`base`** / **`base #N`** titles (same ordering as ``nextSessionTitleInLineage``).
    func resolveLatestSessionIDInLineage(forTitle title: String, lifecycleState: String?) throws -> UUID?

    /// README `subscribe(from_seq:)`: persistence-backed ``AsyncThrowingStream`` of transcript rows.
    ///
    /// Contract:
    /// - `fromSequence` is an inclusive lower bound (`from_seq`), and rows are emitted in strictly increasing `sequence`.
    /// - Backends must apply replay-window retention checks before stream emission using the same policy as `readTranscriptEntries(fromSequence:)`.
    /// - Terminating stream consumption cancels backend tail work without requiring explicit unsubscribe calls.
    /// - Backend strategy may be local polling or multi-host capable (broker/file-watch), but ordering + retention semantics are identical at this seam.
    func subscribeTranscript(conversationID: UUID, fromSequence: Int) -> AsyncThrowingStream<SessionTranscriptEntry, Error>

    /// README `upsert_task` (encoded definition TBD in Gap 7).
    func upsertScheduledTaskDefinition(_ encoded: Data) throws

    /// README `list_tasks`.
    func listScheduledTaskDefinitions(agentId: String?) throws -> [Data]

    /// catalog ``state_meta`` (`key` / `value` TEXT); installation-wide flags (harness README catalog).
    func getStateMetaValue(key: String) throws -> String?
    func setStateMetaValue(key: String, value: String) throws

    /// README `agent_dir`.
    func sessionAgentDirectory(agentId: String) throws -> URL

    /// README `auth_profile`. Reads `agents/<agentId>/auth-profiles.json` as a JSON object keyed by profile `name`; returns encoded value only (see Gap 13).
    func sessionAuthProfile(agentId: String, name: String) throws -> Data?

    /// README `list_agents`.
    ///
    /// Contract:
    /// - Returns logical agent namespace identifiers (`agentId` values).
    /// - Deterministic output order is lexicographic ascending.
    /// - Hidden entries are excluded.
    /// - Local-backed implementations derive identifiers from `agents/` namespaces.
    /// - In-memory implementations provide equivalent logical namespace semantics for tests/CI.
    func listSessionAgentIdentifiers() throws -> [String]

}

/// Harness template name for the single in-process backend (`SessionBackend` in `backends/persistence/README.md`).
typealias SessionBackend = HarnessSessionPersistence

extension HarnessSessionPersistence {
    func acquireTranscriptWriteLock(conversationID: UUID, allowReentrant: Bool, timeoutMs: Int) throws -> any TranscriptWriteLock {
        _ = allowReentrant
        _ = timeoutMs
        throw SessionPersistenceError.unsupportedOperation("acquireTranscriptWriteLock")
    }

    func nextTranscriptSequence(conversationID: UUID) throws -> Int {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("nextTranscriptSequence")
    }

    func appendMirroredTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        _ = conversationID
        _ = entry
        throw SessionPersistenceError.unsupportedOperation("appendMirroredTranscriptEntry")
    }

    func rollBackLastMirroredTranscriptAppend(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        _ = conversationID
        _ = entry
        throw SessionPersistenceError.unsupportedOperation("rollBackLastMirroredTranscriptAppend")
    }

    func applyConversationLifecycle(conversationID: UUID, lifecycle: ConversationLifecycleState) throws {
        _ = conversationID
        _ = lifecycle
        throw SessionPersistenceError.unsupportedOperation("applyConversationLifecycle")
    }

    func endConversation(conversationID: UUID, reason: String?) throws {
        _ = conversationID
        _ = reason
        throw SessionPersistenceError.unsupportedOperation("endConversation")
    }

    func removeSessionConversation(conversationID: UUID) throws {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("removeSessionConversation")
    }

    func reopenConversation(conversationID: UUID) throws {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("reopenConversation")
    }

    func applyConversationTitle(conversationID: UUID, title: String, expectedControlPlaneRevision: UInt64) throws {
        _ = conversationID
        _ = title
        _ = expectedControlPlaneRevision
        throw SessionPersistenceError.unsupportedOperation("applyConversationTitle")
    }

    func transcriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry {
        _ = conversationID
        _ = entryId
        throw SessionPersistenceError.unsupportedOperation("transcriptEntry")
    }

    func childTranscriptEntries(conversationID: UUID, parentEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = parentEntryId
        throw SessionPersistenceError.unsupportedOperation("childTranscriptEntries")
    }

    func transcriptLineage(conversationID: UUID, entryId: SessionEntryID, maxDepth: Int) throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = entryId
        _ = maxDepth
        throw SessionPersistenceError.unsupportedOperation("transcriptLineage")
    }

    func readLineage(conversationID: UUID, leafEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = leafEntryId
        throw SessionPersistenceError.unsupportedOperation("readLineage")
    }

    func activeHeadEntryId(conversationID: UUID) throws -> SessionEntryID? {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("activeHeadEntryId")
    }

    func setActiveHeadEntryId(conversationID: UUID, entryId: SessionEntryID, expectedRevision: UInt64?) throws -> SessionCatalogRecord {
        _ = conversationID
        _ = entryId
        _ = expectedRevision
        throw SessionPersistenceError.unsupportedOperation("setActiveHeadEntryId")
    }

    func appendTranscriptEntries(conversationID: UUID, entries: [SessionTranscriptEntry]) throws {
        _ = conversationID
        _ = entries
        throw SessionPersistenceError.unsupportedOperation("appendTranscriptEntries")
    }

    func forkConversation(
        parentConversationID: UUID,
        atEntryId: SessionEntryID,
        newConversationId: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind,
        childOrigin: ConversationOrigin?
    ) throws -> SessionCatalogRecord {
        _ = parentConversationID
        _ = atEntryId
        _ = newConversationId
        _ = title
        _ = childLineageKind
        _ = childOrigin
        throw SessionPersistenceError.unsupportedOperation("forkConversation")
    }

    func childConversations(parentConversationID: UUID) throws -> [SessionCatalogRecord] {
        _ = parentConversationID
        throw SessionPersistenceError.unsupportedOperation("childConversations")
    }

    func recordTranscriptCompactionEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = conversationID
        _ = payloadJSON
        throw SessionPersistenceError.unsupportedOperation("recordTranscriptCompactionEntry")
    }

    func recordTranscriptBranchSummaryEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = conversationID
        _ = payloadJSON
        throw SessionPersistenceError.unsupportedOperation("recordTranscriptBranchSummaryEntry")
    }

    func appendRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        _ = conversationID
        _ = payload
        throw SessionPersistenceError.unsupportedOperation("appendRunLifecycleTranscriptMarker")
    }

    func searchTranscriptMessages(query: String, agentId: String?, conversationID: UUID?, limit: Int) throws -> [SessionMessageSearchHit] {
        _ = query
        _ = agentId
        _ = conversationID
        _ = limit
        throw SessionPersistenceError.unsupportedOperation("searchTranscriptMessages")
    }

    func firstUserPromptText(conversationID: UUID) throws -> String? {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("firstUserPromptText")
    }

    func latestTranscriptSequence(conversationID: UUID) throws -> Int {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("latestTranscriptSequence")
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) throws -> Bool {
        _ = key
        _ = ttlSeconds
        throw SessionPersistenceError.unsupportedOperation("dedupeCheckAndSet")
    }

    func dedupePeek(key: String) throws -> Bool {
        _ = key
        return false
    }

    func getEngineArtifact(conversationID: UUID, key: String) throws -> Data? {
        _ = conversationID
        _ = key
        return nil
    }

    func putEngineArtifact(conversationID: UUID, key: String, data: Data) throws {
        _ = conversationID
        _ = key
        _ = data
        throw SessionPersistenceError.unsupportedOperation("putEngineArtifact")
    }

    func evictEngineArtifacts(conversationID: UUID, key: String?) throws {
        _ = conversationID
        _ = key
    }

    func listEngineArtifactKeys(conversationID: UUID) throws -> [String] {
        _ = conversationID
        return []
    }

    func toolResultSpillDirectory(conversationID: UUID) -> URL? {
        _ = conversationID
        return nil
    }

    func putToolResultSpillIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult? {
        _ = conversationID
        _ = toolCallId
        _ = content
        return nil
    }

    func isAllowlistedToolResultSpillPath(_ path: String, conversationID: UUID) -> Bool {
        _ = path
        _ = conversationID
        return false
    }

    func putBlob(
        data: Data,
        durability: SessionBlobDurability,
        originalName: String?,
        mimeType: String?,
        trust: String,
        ttlSeconds: Int?,
        lane: SessionBlobEphemeralLane
    ) throws -> SessionBlobRef {
        _ = data
        _ = durability
        _ = originalName
        _ = mimeType
        _ = trust
        _ = ttlSeconds
        _ = lane
        throw SessionPersistenceError.unsupportedOperation("putBlob")
    }

    func putBlobFromURL(
        url: URL,
        durability: SessionBlobDurability,
        trust: String,
        ttlSeconds: Int?,
        maxBytes: Int?,
        lane: SessionBlobEphemeralLane
    ) throws -> SessionBlobRef {
        _ = url
        _ = durability
        _ = trust
        _ = ttlSeconds
        _ = maxBytes
        _ = lane
        throw SessionPersistenceError.unsupportedOperation("putBlobFromURL")
    }

    func getBlob(blobId: String) throws -> Data {
        _ = blobId
        throw SessionPersistenceError.unsupportedOperation("getBlob")
    }

    func statBlob(blobId: String) throws -> SessionBlobRef {
        _ = blobId
        throw SessionPersistenceError.unsupportedOperation("statBlob")
    }

    func blobPath(blobId: String) throws -> URL? {
        _ = blobId
        throw SessionPersistenceError.unsupportedOperation("blobPath")
    }

    func promoteBlob(blobId: String) throws -> SessionBlobRef {
        _ = blobId
        throw SessionPersistenceError.unsupportedOperation("promoteBlob")
    }

    func deleteBlob(blobId: String) throws {
        _ = blobId
        throw SessionPersistenceError.unsupportedOperation("deleteBlob")
    }

    func sweepExpiredBlobs() throws -> Int {
        throw SessionPersistenceError.unsupportedOperation("sweepExpiredBlobs")
    }

    func reclaimUnreferencedDurableBlobs(liveBlobIds: Set<String>, trashRetentionSeconds: Int) throws -> SessionBlobReclaimCounts {
        _ = liveBlobIds
        _ = trashRetentionSeconds
        throw SessionPersistenceError.unsupportedOperation("reclaimUnreferencedDurableBlobs")
    }

    func openReferencedDurableBlob(blobId: String, conversationID: UUID?) throws -> Data {
        _ = blobId
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("openReferencedDurableBlob")
    }

    func verifyTranscript(conversationID: UUID) throws -> TranscriptVerifyReport {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("verifyTranscript")
    }

    func repairQuarantinedTranscript(conversationID: UUID) throws {
        _ = conversationID
        throw SessionPersistenceError.unsupportedOperation("repairQuarantinedTranscript")
    }

    func appendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) throws -> UUID {
        _ = jobId
        _ = payload
        _ = idempotencyKey
        throw SessionPersistenceError.unsupportedOperation("appendTaskRun")
    }

    func tailTaskRuns(jobId: String, limit: Int) throws -> [SessionHarnessTaskRunRecord] {
        _ = jobId
        _ = limit
        return []
    }

    func latestUndeliveredTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord? {
        _ = jobId
        return nil
    }

    func markTaskRunDelivered(runId: UUID) throws {
        _ = runId
        throw SessionPersistenceError.unsupportedOperation("markTaskRunDelivered")
    }

    // MARK: - README SessionBackend defaults

    func createConversation(_ params: SessionConversationCreationParams) throws -> SessionCatalogRecord {
        _ = params
        throw SessionPersistenceError.unsupportedOperation("createConversation")
    }

    func updateSessionConversation(conversationID: UUID, patch: SessionConversationUpdatePatch, expectedRevision: UInt64?) throws -> SessionCatalogRecord {
        _ = conversationID
        _ = patch
        _ = expectedRevision
        throw SessionPersistenceError.unsupportedOperation("updateSessionConversation")
    }

    func listConversations(_ filter: SessionConversationListFilter, limit: Int, cursor: String?) throws -> SessionCatalogPage {
        _ = filter
        _ = limit
        _ = cursor
        throw SessionPersistenceError.unsupportedOperation("listConversations")
    }

    func resolveSessionByTitle(_ title: String, lifecycleState: String?) throws -> UUID? {
        _ = title
        _ = lifecycleState
        throw SessionPersistenceError.unsupportedOperation("resolveSessionByTitle")
    }

    func nextSessionTitleInLineage(forTitle title: String, lifecycleState: String?) throws -> String? {
        _ = title
        _ = lifecycleState
        throw SessionPersistenceError.unsupportedOperation("nextSessionTitleInLineage")
    }

    func resolveLatestSessionIDInLineage(forTitle title: String, lifecycleState: String?) throws -> UUID? {
        _ = title
        _ = lifecycleState
        throw SessionPersistenceError.unsupportedOperation("resolveLatestSessionIDInLineage")
    }

    func subscribeTranscript(conversationID: UUID, fromSequence: Int) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: SessionPersistenceError.unsupportedOperation("subscribeTranscript")
            )
        }
    }

    func upsertScheduledTaskDefinition(_ encoded: Data) throws {
        _ = encoded
        throw SessionPersistenceError.unsupportedOperation("upsertScheduledTaskDefinition")
    }

    func listScheduledTaskDefinitions(agentId: String?) throws -> [Data] {
        _ = agentId
        throw SessionPersistenceError.unsupportedOperation("listScheduledTaskDefinitions")
    }

    func getStateMetaValue(key: String) throws -> String? {
        _ = key
        throw SessionPersistenceError.unsupportedOperation("getStateMetaValue")
    }

    func setStateMetaValue(key: String, value: String) throws {
        _ = key
        _ = value
        throw SessionPersistenceError.unsupportedOperation("setStateMetaValue")
    }

    func sessionAgentDirectory(agentId: String) throws -> URL {
        _ = agentId
        throw SessionPersistenceError.unsupportedOperation("sessionAgentDirectory")
    }

    func sessionAuthProfile(agentId: String, name: String) throws -> Data? {
        _ = agentId
        _ = name
        throw SessionPersistenceError.unsupportedOperation("sessionAuthProfile")
    }

    func listSessionAgentIdentifiers() throws -> [String] {
        throw SessionPersistenceError.unsupportedOperation("listSessionAgentIdentifiers")
    }

}

extension HarnessSessionPersistence {
    func forkConversation(
        parentConversationID: UUID,
        atEntryId: SessionEntryID,
        newConversationId: UUID,
        title: String?
    ) throws -> SessionCatalogRecord {
        try forkConversation(
            parentConversationID: parentConversationID,
            atEntryId: atEntryId,
            newConversationId: newConversationId,
            title: title,
            childLineageKind: .branch,
            childOrigin: nil
        )
    }
}

// MARK: - README `record_compaction` / `record_branch_summary` (Gap 15)

extension HarnessSessionPersistence {
    /// README **`record_compaction`**: encodes into ``ConversationCheckpointTopicEventWire`` and calls ``recordTranscriptCompactionEntry(conversationID:payloadJSON:)``.
    ///
    /// Default checkpoint kinds match Context Engine compaction notifications; pass explicit coverage / invalidation fields when bridging other checkpoint variants.
    func recordTranscriptCompaction(
        conversationID: UUID,
        summary: String,
        firstKeptEntryID: SessionEntryID,
        tokensBefore: Int,
        details: [String: SessionTranscriptJSONValue]? = nil,
        harnessCheckpointKind: String? = HarnessCheckpointWireKind.contextCompaction.rawValue,
        compactionCheckpointKind: String? = "summarized",
        coveredRawMessageIDs: [SessionEntryID]? = nil,
        basedOnTailMessageID: SessionEntryID? = nil,
        invalidatedCheckpointKinds: [String]? = nil
    ) throws -> Int {
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: conversationID,
            harnessCheckpointKind: harnessCheckpointKind,
            compactionCheckpointKind: compactionCheckpointKind,
            coveredRawMessageIDs: coveredRawMessageIDs,
            basedOnTailMessageID: basedOnTailMessageID,
            invalidatedCheckpointKinds: invalidatedCheckpointKinds,
            summary: summary,
            firstKeptEntryID: firstKeptEntryID,
            tokensBefore: tokensBefore,
            details: details
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(wire)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "compaction payload utf-8 encode failed")
        }
        return try recordTranscriptCompactionEntry(conversationID: conversationID, payloadJSON: json)
    }

    /// README **`record_branch_summary`**: encodes into ``SessionBranchSummaryTranscriptPayload`` and calls ``recordTranscriptBranchSummaryEntry(conversationID:payloadJSON:)``.
    func recordTranscriptBranchSummary(
        conversationID: UUID,
        fromEntryID: SessionEntryID,
        summary: String,
        details: [String: SessionTranscriptJSONValue]? = nil,
        payloadVersion: Int = 1
    ) throws -> Int {
        let payload = SessionBranchSummaryTranscriptPayload(
            version: payloadVersion,
            summary: summary,
            fromEntryID: fromEntryID,
            details: details
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "branch summary payload utf-8 encode failed")
        }
        return try recordTranscriptBranchSummaryEntry(conversationID: conversationID, payloadJSON: json)
    }

    func forkConversation(
        parentConversationID: UUID,
        atMessageID: UUID,
        newConversationId: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil
    ) throws -> SessionCatalogRecord {
        try forkConversation(
            parentConversationID: parentConversationID,
            atEntryId: SessionEntryID.fromMessageUUID(atMessageID),
            newConversationId: newConversationId,
            title: title,
            childLineageKind: childLineageKind,
            childOrigin: childOrigin
        )
    }

    func transcriptEntry(conversationID: UUID, messageID: UUID) throws -> SessionTranscriptEntry {
        try transcriptEntry(
            conversationID: conversationID,
            entryId: SessionEntryID.fromMessageUUID(messageID)
        )
    }

    func setActiveHeadEntryId(
        conversationID: UUID,
        messageID: UUID,
        expectedRevision: UInt64?
    ) throws -> SessionCatalogRecord {
        try setActiveHeadEntryId(
            conversationID: conversationID,
            entryId: SessionEntryID.fromMessageUUID(messageID),
            expectedRevision: expectedRevision
        )
    }

    func recordTranscriptCompaction(
        conversationID: UUID,
        summary: String,
        firstKeptMessageID: UUID,
        tokensBefore: Int,
        details: [String: SessionTranscriptJSONValue]? = nil,
        harnessCheckpointKind: String? = HarnessCheckpointWireKind.contextCompaction.rawValue,
        compactionCheckpointKind: String? = "summarized",
        coveredRawMessageIDs: [UUID]? = nil,
        basedOnTailMessageID: UUID? = nil,
        invalidatedCheckpointKinds: [String]? = nil
    ) throws -> Int {
        try recordTranscriptCompaction(
            conversationID: conversationID,
            summary: summary,
            firstKeptEntryID: SessionEntryID.fromMessageUUID(firstKeptMessageID),
            tokensBefore: tokensBefore,
            details: details,
            harnessCheckpointKind: harnessCheckpointKind,
            compactionCheckpointKind: compactionCheckpointKind,
            coveredRawMessageIDs: coveredRawMessageIDs.map(SessionEntryID.fromMessageUUIDs),
            basedOnTailMessageID: basedOnTailMessageID.map(SessionEntryID.fromMessageUUID),
            invalidatedCheckpointKinds: invalidatedCheckpointKinds
        )
    }
}

extension HarnessSessionPersistence {
    func acquireTranscriptWriteLock(conversationID: UUID, allowReentrant: Bool) throws -> any TranscriptWriteLock {
        try acquireTranscriptWriteLock(
            conversationID: conversationID,
            allowReentrant: allowReentrant,
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs
        )
    }
}
