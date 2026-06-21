//
//  Disk-free ``HarnessSessionPersistence`` for fast unit tests (linear search; no FTS).
//

import Foundation

/// In-memory harness persistence (no SQLite / JSONL / FTS). Thread-safe via ``NSRecursiveLock`` (nested catalog reads).
/// Use of @unchecked Sendable is valid here
final class InMemoryHarnessSessionPersistence: HarnessSessionPersistence, @unchecked Sendable {
    private let agentId: String
    /// Synthetic v2 layout root (temp dir) for Gap 13 per-agent paths (`agents/`, `auth-profiles.json`).
    private let layoutRoot: URL
    private let gate = NSRecursiveLock()
    private var catalogs: [UUID: SessionCatalogRecord] = [:]
    private var transcripts: [UUID: [SessionTranscriptEntry]] = [:]
    private var engineCache: [UUID: [String: Data]] = [:]
    private var dedupe: [String: TimeInterval] = [:]
    private var cronLinesByJob: [String: [Data]] = [:]
    private struct PendingHarnessTask: Sendable {
        var jobId: String
        var runId: UUID
        var payload: Data
        var idempotencyKey: String?
        var createdAt: Date
        var delivered: Bool
    }

    private var pendingTasks: [PendingHarnessTask] = []
    private var stateMeta: [String: String] = [:]
    private struct ScheduledDefinition: Sendable {
        var agentId: String?
        var payload: Data
    }

    private var scheduledDefinitions: [String: ScheduledDefinition] = [:]
    private struct StoredBlob: Sendable {
        var data: Data
        var ref: SessionBlobRef
        var lane: SessionBlobEphemeralLane?
        var trashedAt: Date?
    }

    private var blobs: [String: StoredBlob] = [:]
    private let lockRegistry = InProcessTranscriptWriteLockRegistry()
    private static let lineageCap = 256

    init(agentId: String = SessionPersistenceLayout.defaultAgentId) {
        self.agentId = agentId
        self.layoutRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InMemHarness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: layoutRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: layoutRoot)
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        gate.lock()
        defer { gate.unlock() }
        return try body()
    }

    // MARK: - CatalogPersistence

    func listCatalogConversations() throws -> [SessionCatalogRecord] {
        sync {
            catalogs.values.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        }
    }

    func catalogConversation(id: UUID) throws -> SessionCatalogRecord? {
        sync { catalogs[id] }
    }

    func listCatalogConversationsPage(cursor: String?, limit: Int) throws -> SessionCatalogPage {
        sync {
            keyedCatalogPage(from: sortedCatalogRecords(), cursor: cursor, limit: limit)
        }
    }

    func listConversations(_ filter: SessionConversationListFilter, limit: Int, cursor: String?) throws -> SessionCatalogPage {
        sync {
            let filtered = sortedCatalogRecords().filter { filter.matches(record: $0) }
            return keyedCatalogPage(from: filtered, cursor: cursor, limit: limit)
        }
    }

    private func sortedCatalogRecords() -> [SessionCatalogRecord] {
        catalogs.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private func keyedCatalogPage(from rows: [SessionCatalogRecord], cursor: String?, limit: Int) -> SessionCatalogPage {
        var rows = rows
        if let decoded = SessionCatalogKeysetCursor.decode(cursor) {
            let ts = decoded.updatedAtUnixSeconds
            let cutId = decoded.idString
                let cutDate = Date(timeIntervalSince1970: ts)
            rows = rows.filter { r in
                r.updatedAt < cutDate || (r.updatedAt == cutDate && r.id.uuidString < cutId)
            }
        }
        guard limit > 0 else { return SessionCatalogPage(records: [], nextCursor: nil) }
        let page = Array(rows.prefix(limit))
        let next: String?
        if page.count < limit {
            next = nil
        } else if let last = page.last {
            next = SessionCatalogKeysetCursor.encode(updatedAt: last.updatedAt, id: last.id)
        } else {
            next = nil
        }
        return SessionCatalogPage(records: page, nextCursor: next)
    }

    // MARK: - TranscriptPersistence

    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry] {
        try sync {
            guard catalogs[conversationID] != nil else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            let latest = transcripts[conversationID]?.map(\.sequence).max() ?? 0
            if let from = request.fromSequence {
                try TranscriptTailRetentionPolicy.fromEnvironmentOrDefault().requireReplayWindow(
                    conversationID: conversationID,
                    clientInclusiveFloor: from,
                    latestSequence: latest
                )
            }
            let entries = (transcripts[conversationID] ?? []).sorted { $0.sequence < $1.sequence }
            return SessionJSONLTranscriptReader.filter(entries: entries, request: request)
        }
    }

    func latestTranscriptSequence(conversationID: UUID) throws -> Int {
        try sync {
            guard catalogs[conversationID] != nil else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            return transcripts[conversationID]?.map(\.sequence).max() ?? 0
        }
    }

    func subscribeTranscript(conversationID: UUID, fromSequence: Int) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        let box = InMemoryHarnessSubscribeContext(mem: self, conversationID: conversationID)
        return TranscriptSubscriptionStream.entryEvents(
            conversationID: conversationID,
            inclusiveFrom: fromSequence,
            retention: TranscriptTailRetentionPolicy.fromEnvironmentOrDefault(),
            pollInterval: TranscriptSubscriptionStream.pollIntervalFromEnvironmentOrDefault(),
            preferredTailStrategy: .polling,
            readEntries: { try box.read($0) },
            latestSequence: { try box.latest() }
        )
    }

    // MARK: - HarnessSessionPersistence

    func bootstrapEmptyConversation(_ record: SessionCatalogRecord) throws {
        sync {
            let occupied = Set<String>(
                catalogs.values.compactMap { existing in
                    guard existing.id != record.id, let t = existing.title else { return nil }
                    return t
                }
            )
            var row = record
            row.agentId = agentId
            row.messageCount = 0
            SessionCatalogTitleDisambiguation.apply(to: &row, occupiedNonNullTitles: occupied)
            catalogs[row.id] = row
            transcripts[row.id] = []
        }
    }

    func appendTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let lock = lockRegistry.acquire(conversationID: conversationID)
        lock.acquire()
        defer { lock.unlock() }
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
    }

    func appendTranscriptEntryUnlocked(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        switch entry.type {
        case .conversationJournal, .derivedJournal:
            _ = try SessionTranscriptPayloadAllowlist.decodeTranscriptJournalEnvelope(entry.payloadJSON)
        default:
            break
        }
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            if cat.transcriptIntegrity?.state == .quarantined {
                throw SessionPersistenceError.transcriptQuarantined(
                    conversationID: conversationID,
                    reason: cat.transcriptIntegrity?.reason ?? "transcript quarantined"
                )
            }
            var list = transcripts[conversationID] ?? []
            list.append(entry)
            transcripts[conversationID] = list
            let increment = entry.type.countsTowardSessionCatalogMessageTotal ? 1 : 0
            cat.messageCount = max(0, cat.messageCount) + increment
            cat.updatedAt = Date()
            if entry.type == .message || entry.type == .system {
                cat.headEntryId = entry.entryId
            }
            catalogs[conversationID] = cat
        }
    }

    func acquireTranscriptWriteLock(conversationID: UUID, allowReentrant: Bool, timeoutMs: Int) throws -> any TranscriptWriteLock {
        _ = allowReentrant
        _ = timeoutMs
        guard sync({ catalogs[conversationID] != nil }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let lock = lockRegistry.acquire(conversationID: conversationID)
        lock.acquire()
        return lock
    }

    func appendMirroredTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
    }

    func rollBackLastMirroredTranscriptAppend(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        sync {
            guard var cat = catalogs[conversationID], var list = transcripts[conversationID], let last = list.last else { return }
            guard last.sequence == entry.sequence, last.entryId == entry.entryId else { return }
            list.removeLast()
            transcripts[conversationID] = list
            cat.messageCount = max(0, (list.filter(\.type.countsTowardSessionCatalogMessageTotal).count))
            cat.updatedAt = Date()
            catalogs[conversationID] = cat
        }
    }

    func replaceTranscriptBody(conversationID: UUID, entries: [SessionTranscriptEntry]) throws {
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            transcripts[conversationID] = entries.sorted { $0.sequence < $1.sequence }
            cat.messageCount = entries.filter(\.type.countsTowardSessionCatalogMessageTotal).count
            cat.updatedAt = Date()
            if let head = entries.last(where: { $0.type == .message || $0.type == .system }) {
                cat.headEntryId = head.entryId
            }
            catalogs[conversationID] = cat
            TranscriptJournalTailCache.invalidate(conversationID: conversationID)
        }
    }

    func nextTranscriptSequence(conversationID: UUID) throws -> Int {
        try latestTranscriptSequence(conversationID: conversationID) + 1
    }

    func applyConversationLifecycle(conversationID: UUID, lifecycle: ConversationLifecycleState) throws {
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            cat.lifecycleStateRaw = lifecycle.rawValue
            cat.updatedAt = Date()
            catalogs[conversationID] = cat
        }
    }

    func endConversation(conversationID: UUID, reason: String?) throws {
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            cat.lifecycleStateRaw = ConversationLifecycleState.archived.rawValue
            cat.endedAt = Date()
            cat.endReason = reason
            cat.updatedAt = Date()
            catalogs[conversationID] = cat
        }
    }

    func removeSessionConversation(conversationID: UUID) throws {
        try sync {
            guard catalogs.removeValue(forKey: conversationID) != nil else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            transcripts.removeValue(forKey: conversationID)
            engineCache.removeValue(forKey: conversationID)
            TranscriptJournalTailCache.invalidate(conversationID: conversationID)
        }
    }

    func reopenConversation(conversationID: UUID) throws {
        try applyConversationLifecycle(conversationID: conversationID, lifecycle: .active)
    }

    func applyConversationTitle(conversationID: UUID, title: String, expectedControlPlaneRevision: UInt64) throws {
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            let expected = Int(clamping: expectedControlPlaneRevision)
            guard cat.controlPlaneRevision == expected else {
                throw SessionPersistenceError.controlPlaneRevisionConflict(
                    conversationID: conversationID,
                    expectedRevision: expectedControlPlaneRevision,
                    actualRevision: UInt64(cat.controlPlaneRevision)
                )
            }
            let sanitized = SessionTitleResolution.sanitizedTitle(title)
            try assertNoDuplicateAgentTitle(forNewTitle: sanitized, excludingConversationID: conversationID)
            cat.title = sanitized
            cat.topic = sanitized
            cat.controlPlaneRevision = expected + 1
            cat.updatedAt = Date()
            catalogs[conversationID] = cat
        }
    }

    func transcriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry {
        let all = try readTranscriptEntries(conversationID: conversationID, request: .full)
        guard let e = all.first(where: { $0.entryId == entryId }) else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
        }
        return e
    }

    func childTranscriptEntries(conversationID: UUID, parentEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        try readTranscriptEntries(conversationID: conversationID, request: .full).filter { $0.parentEntryId == parentEntryId }
    }

    func transcriptLineage(conversationID: UUID, entryId: SessionEntryID, maxDepth: Int) throws -> [SessionTranscriptEntry] {
        _ = maxDepth
        return try readLineage(conversationID: conversationID, leafEntryId: entryId).reversed()
    }

    func readLineage(conversationID: UUID, leafEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        let all = try readTranscriptEntries(conversationID: conversationID, request: .full)
        let byId = [SessionEntryID: SessionTranscriptEntry](uniqueKeysWithValues: all.map { ($0.entryId, $0) })
        guard byId[leafEntryId] != nil else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: leafEntryId)
        }
        return SessionTranscriptLineage.readLineageRootToLeaf(
            leafEntryId: leafEntryId,
            entryById: byId,
            maxDepth: Self.lineageCap
        )
    }

    func activeHeadEntryId(conversationID: UUID) throws -> SessionEntryID? {
        try catalogConversation(id: conversationID)?.headEntryId
    }

    func setActiveHeadEntryId(
        conversationID: UUID,
        entryId: SessionEntryID,
        expectedRevision: UInt64?
    ) throws -> SessionCatalogRecord {
        return try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            guard (transcripts[conversationID] ?? []).contains(where: { $0.entryId == entryId }) else {
                throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
            }
            if let head = cat.headEntryId {
                let all = transcripts[conversationID] ?? []
                let byId = [SessionEntryID: SessionTranscriptEntry](uniqueKeysWithValues: all.map { ($0.entryId, $0) })
                guard SessionTranscriptLineage.isAncestorOrSelf(
                    candidate: entryId,
                    headEntryId: head,
                    entryById: byId,
                    maxDepth: Self.lineageCap
                ) else {
                    throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
                }
            }
            if let expectedRevision, UInt64(cat.controlPlaneRevision) != expectedRevision {
                throw SessionPersistenceError.controlPlaneRevisionConflict(
                    conversationID: conversationID,
                    expectedRevision: expectedRevision,
                    actualRevision: UInt64(cat.controlPlaneRevision)
                )
            }
            cat.headEntryId = entryId
            cat.controlPlaneRevision = cat.controlPlaneRevision + 1
            cat.updatedAt = Date()
            catalogs[conversationID] = cat
            return cat
        }
    }

    func appendTranscriptEntries(conversationID: UUID, entries: [SessionTranscriptEntry]) throws {
        let lock = lockRegistry.acquire(conversationID: conversationID)
        lock.acquire()
        defer { lock.unlock() }
        for e in entries {
            let seq = try nextTranscriptSequence(conversationID: conversationID)
            var next = e
            next.sequence = seq
            try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: next)
        }
    }

    func updateTranscriptEntryPayload(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let lock = lockRegistry.acquire(conversationID: conversationID)
        lock.acquire()
        defer { lock.unlock() }
        try sync {
            guard catalogs[conversationID] != nil else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            guard var rows = transcripts[conversationID],
                  let index = rows.firstIndex(where: { $0.entryId == entry.entryId })
            else {
                throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entry.entryId)
            }
            rows[index] = entry
            transcripts[conversationID] = rows
        }
    }

    func forkConversation(
        parentConversationID: UUID,
        atEntryId: SessionEntryID,
        newConversationId: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil
    ) throws -> SessionCatalogRecord {
        guard let base = try catalogConversation(id: parentConversationID) else {
            throw SessionPersistenceError.conversationNotFound(parentConversationID)
        }
        let parentEntries = try readTranscriptEntries(conversationID: parentConversationID, request: .full)
        guard parentEntries.first(where: { $0.entryId == atEntryId }) != nil else {
            throw SessionPersistenceError.entryNotFound(conversationID: parentConversationID, entryId: atEntryId)
        }
        let prefix = try readLineage(conversationID: parentConversationID, leafEntryId: atEntryId)
        let child = base.normalizedForkChildRecord(
            newConversationID: newConversationId,
            parentConversationID: parentConversationID,
            forkAnchorEntryID: atEntryId,
            requestedTitle: title,
            catalogAgentID: agentId,
            childLineageKind: childLineageKind,
            childOrigin: childOrigin
        )
        try bootstrapEmptyConversation(child)
        let transcriptPrefix = prefix.filter { $0.type == .message || $0.type == .system }
        var entryIdMap: [SessionEntryID: SessionEntryID] = [:]
        for source in transcriptPrefix {
            entryIdMap[source.entryId] = .generate()
        }
        for source in transcriptPrefix {
            var copy = source
            copy.entryId = entryIdMap[source.entryId] ?? source.entryId
            copy.parentEntryId = source.parentEntryId.flatMap { entryIdMap[$0] }
            try appendTranscriptEntry(conversationID: newConversationId, entry: copy)
        }
        if let mappedHead = entryIdMap[atEntryId] {
            _ = try setActiveHeadEntryId(
                conversationID: newConversationId,
                entryId: mappedHead,
                expectedRevision: nil
            )
        }
        guard let row = try catalogConversation(id: newConversationId) else {
            throw SessionPersistenceError.catalogStoreFailed(operation: "fork_missing_child_row", sqliteCode: nil)
        }
        return row
    }

    func childConversations(parentConversationID: UUID) throws -> [SessionCatalogRecord] {
        try listCatalogConversations().filter { $0.parentConversationID == parentConversationID }
    }

    func recordTranscriptCompactionEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = try SessionTranscriptPayloadAllowlist.decodeCompactionCheckpointPayload(payloadJSON)
        return try recordAux(conversationID: conversationID, type: .compaction, payloadJSON: payloadJSON)
    }

    func recordTranscriptBranchSummaryEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = try SessionTranscriptPayloadAllowlist.decodeBranchSummaryPayload(payloadJSON)
        return try recordAux(conversationID: conversationID, type: .branchSummary, payloadJSON: payloadJSON)
    }

    func appendRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        let json = try payload.encodedJSONString()
        try SessionTranscriptPayloadAllowlist.assertRunLifecycleMarkerPayloadAllowed(json)
        try recordCustomAux(conversationID: conversationID, harnessTypeRaw: payload.customType, payloadJSON: json)
    }

    private func recordCustomAux(conversationID: UUID, harnessTypeRaw: String, payloadJSON: String) throws {
        let seq = try nextTranscriptSequence(conversationID: conversationID)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: nil,
            type: .custom,
            harnessTypeRaw: harnessTypeRaw,
            timestamp: Date(),
            payloadJSON: payloadJSON
        )
        try appendTranscriptEntry(conversationID: conversationID, entry: entry)
    }

    private func recordAux(conversationID: UUID, type: SessionTranscriptEntryType, payloadJSON: String) throws -> Int {
        let seq = try nextTranscriptSequence(conversationID: conversationID)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: nil,
            type: type,
            timestamp: Date(),
            payloadJSON: payloadJSON
        )
        try appendTranscriptEntry(conversationID: conversationID, entry: entry)
        return seq
    }

    func searchTranscriptMessages(query: String, agentId: String?, conversationID: UUID?, limit: Int) throws -> [SessionMessageSearchHit] {
        let match = FTS5QuerySanitizer.matchAndPhrases(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if match.isEmpty || limit <= 0 { return [] }
        let phrases = FTS5QuerySanitizer.phraseTerms(fromMatchOperand: match)
        if phrases.isEmpty { return [] }
        return sync {
            var hits: [SessionMessageSearchHit] = []
            let convIds: [UUID]
            if let conversationID {
                guard catalogs[conversationID] != nil else { return [] }
                convIds = [conversationID]
            } else {
                convIds = Array(catalogs.keys)
            }
            outer: for cid in convIds {
                if let agentId {
                    guard let rec = catalogs[cid], rec.agentId == agentId else { continue }
                }
                let entries = (transcripts[cid] ?? []).sorted { $0.sequence < $1.sequence }
                for e in entries {
                    let body = SessionMessageContentExtractor.ftsIndexedContent(for: e)
                    guard SessionMessageSearchSubstringFallback.contentMatchesPhrases(body, phrases: phrases) else { continue }
                    hits.append(
                        SessionMessageSearchHit(
                            conversationID: cid,
                            entryId: e.entryId,
                            sequence: e.sequence,
                            snippet: SessionMessageSearchSubstringFallback.highlightedSnippet(content: body, phrases: phrases),
                            score: SessionMessageSearchSubstringFallback.nonFTSScoreRank,
                            timestamp: e.timestamp
                        )
                    )
                    if hits.count >= limit { break outer }
                }
            }
            return hits
        }
    }

    func firstUserPromptText(conversationID: UUID) throws -> String? {
        guard let cat = try catalogConversation(id: conversationID) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        if let fp = cat.firstUserPrompt { return fp }
        let entries = try readTranscriptEntries(conversationID: conversationID, request: .full)
        for e in entries {
            if let p = SessionTranscriptMapping.inferFirstUserPromptIfNeeded(from: e) { return p }
        }
        return nil
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) throws -> Bool {
        let now = Date()
        return sync {
            let ts = now.timeIntervalSince1970
            dedupe = dedupe.filter { _, exp in exp >= ts }
            let expires = now.addingTimeInterval(TimeInterval(ttlSeconds)).timeIntervalSince1970
            if let existing = dedupe[key], existing >= ts {
                return false
            }
            dedupe[key] = expires
            return true
        }
    }

    func dedupePeek(key: String) throws -> Bool {
        let now = Date()
        return sync {
            let ts = now.timeIntervalSince1970
            dedupe = dedupe.filter { _, exp in exp >= ts }
            guard let existing = dedupe[key] else { return false }
            return existing >= ts
        }
    }

    func getEngineArtifact(conversationID: UUID, key: String) throws -> Data? {
        sync { engineCache[conversationID]?[key] }
    }

    func putEngineArtifact(conversationID: UUID, key: String, data: Data) throws {
        sync {
            if engineCache[conversationID] == nil { engineCache[conversationID] = [:] }
            engineCache[conversationID]?[key] = data
        }
    }

    func evictEngineArtifacts(conversationID: UUID, key: String?) throws {
        sync {
            if let key {
                engineCache[conversationID]?[key] = nil
            } else {
                engineCache[conversationID] = nil
            }
        }
    }

    func listEngineArtifactKeys(conversationID: UUID) throws -> [String] {
        sync {
            guard let keys = engineCache[conversationID]?.keys else {
                return []
            }
            return keys.sorted()
        }
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
        try sync {
            let maxBytes = SessionPersistenceConfiguration.blobMaxBytes
            guard data.count <= maxBytes else {
                throw SessionPersistenceError.blobTooLarge(size: data.count, maxBytes: maxBytes)
            }
            if durability == .ephemeral, ttlSeconds == nil {
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "ephemeral blob requires ttlSeconds")
            }
            let blobId = SessionBlobStore.sha256Hex(data)
            if var existing = blobs[blobId] {
                if existing.trashedAt != nil {
                    existing.trashedAt = nil
                    blobs[blobId] = existing
                }
                return existing.ref
            }
            let now = Date()
            let expiresAt = durability == .ephemeral ? now.addingTimeInterval(TimeInterval(ttlSeconds ?? 120)) : nil
            let ref = SessionBlobRef(
                id: blobId,
                mimeType: SessionBlobMIME.sniff(data: data, hint: mimeType),
                size: data.count,
                originalName: originalName,
                durability: durability,
                trust: trust,
                createdAt: now,
                expiresAt: expiresAt
            )
            blobs[blobId] = StoredBlob(data: data, ref: ref, lane: durability == .ephemeral ? lane : nil, trashedAt: nil)
            return ref
        }
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
        throw SessionPersistenceError.unsupportedOperation("putBlobFromURL in-memory")
    }

    func getBlob(blobId: String) throws -> Data {
        try sync {
            let id = SessionBlobStore.normalizeBlobId(blobId)
            guard var stored = blobs[id] else {
                throw SessionPersistenceError.blobNotFound(blobId: id)
            }
            if stored.trashedAt != nil {
                stored.trashedAt = nil
                blobs[id] = stored
            }
            if let expiresAt = stored.ref.expiresAt, Date() >= expiresAt {
                throw SessionPersistenceError.blobExpired(blobId: id, expiredAt: expiresAt)
            }
            return stored.data
        }
    }

    func statBlob(blobId: String) throws -> SessionBlobRef {
        try sync {
            let id = SessionBlobStore.normalizeBlobId(blobId)
            guard let stored = blobs[id] else {
                throw SessionPersistenceError.blobNotFound(blobId: id)
            }
            if let expiresAt = stored.ref.expiresAt, Date() >= expiresAt {
                throw SessionPersistenceError.blobExpired(blobId: id, expiredAt: expiresAt)
            }
            return stored.ref
        }
    }

    func blobPath(blobId: String) throws -> URL? {
        _ = blobId
        return nil
    }

    func promoteBlob(blobId: String) throws -> SessionBlobRef {
        try sync {
            let id = SessionBlobStore.normalizeBlobId(blobId)
            guard var stored = blobs[id] else {
                throw SessionPersistenceError.blobNotFound(blobId: id)
            }
            stored.ref.durability = .durable
            stored.ref.expiresAt = nil
            stored.lane = nil
            stored.trashedAt = nil
            blobs[id] = stored
            return stored.ref
        }
    }

    func deleteBlob(blobId: String) throws {
        try sync {
            let id = SessionBlobStore.normalizeBlobId(blobId)
            guard blobs[id] != nil else {
                throw SessionPersistenceError.blobNotFound(blobId: id)
            }
            blobs[id] = nil
        }
    }

    func sweepExpiredBlobs() throws -> Int {
        sync {
            let now = Date()
            let expired = blobs.filter { _, stored in
                guard let expiresAt = stored.ref.expiresAt else { return false }
                return now >= expiresAt
            }.map(\.key)
            for key in expired { blobs[key] = nil }
            return expired.count
        }
    }

    func reclaimUnreferencedDurableBlobs(liveBlobIds: Set<String>, trashRetentionSeconds: Int) throws -> SessionBlobReclaimCounts {
        sync {
            let now = Date()
            let retention = TimeInterval(trashRetentionSeconds)
            var trashed = 0
            for (id, stored) in blobs where stored.ref.durability == .durable && !liveBlobIds.contains(id) && stored.trashedAt == nil {
                blobs[id]?.trashedAt = now
                trashed += 1
            }
            var hardDeleted = 0
            let removable = blobs.filter { id, stored in
                stored.ref.durability == .durable
                    && stored.trashedAt != nil
                    && !liveBlobIds.contains(id)
                    && now.timeIntervalSince(stored.trashedAt!) >= retention
            }.map(\.key)
            for key in removable {
                blobs[key] = nil
                hardDeleted += 1
            }
            return SessionBlobReclaimCounts(trashed: trashed, hardDeleted: hardDeleted)
        }
    }

    func openReferencedDurableBlob(blobId: String, conversationID: UUID?) throws -> Data {
        let normalized = SessionBlobStore.normalizeBlobId(blobId)
        do {
            return try getBlob(blobId: normalized)
        } catch SessionPersistenceError.blobNotFound {
            throw SessionPersistenceError.durableBlobMissing(blobId: normalized, conversationID: conversationID)
        }
    }

    func verifyTranscript(conversationID: UUID) throws -> TranscriptVerifyReport {
        try sync {
            guard catalogs[conversationID] != nil else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            let latest = (transcripts[conversationID] ?? []).map(\.sequence).max() ?? 0
            return TranscriptVerifyReport(
                conversationID: conversationID,
                catalogLatestSequence: latest,
                lastCleanJSONLSequence: latest,
                isTailConfined: false,
                isLosslesslyRepairable: false,
                damageClass: .clean,
                reason: nil,
                maintenanceAction: .none
            )
        }
    }

    func repairQuarantinedTranscript(conversationID: UUID) throws {
        try sync {
            guard var cat = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            guard cat.transcriptIntegrity?.state == .quarantined else {
                throw SessionPersistenceError.unsupportedOperation("transcript not quarantined")
            }
            cat.transcriptIntegrity = nil
            catalogs[conversationID] = cat
        }
    }

    func appendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) throws -> UUID {
        try sync {
            if let idempotencyKey {
                if let existing = pendingTasks.first(where: { $0.idempotencyKey == idempotencyKey }) {
                    if existing.jobId != jobId || existing.payload != payload {
                        throw SessionPersistenceError.idempotencyHit(
                            idempotencyKey: idempotencyKey,
                            existingRunId: existing.runId
                        )
                    }
                    return existing.runId
                }
            }
            let runId = UUID()
            let createdAt = Date()
            pendingTasks.append(
                PendingHarnessTask(
                    jobId: jobId,
                    runId: runId,
                    payload: payload,
                    idempotencyKey: idempotencyKey,
                    createdAt: createdAt,
                    delivered: false
                )
            )
            var lines = cronLinesByJob[jobId] ?? []
            if let data = try? JSONEncoder().encode(
                SessionHarnessTaskRunRecord(
                    runId: runId,
                    jobId: jobId,
                    createdAt: createdAt,
                    payload: payload,
                    idempotencyKey: idempotencyKey
                )
            ) {
                lines.append(data)
                cronLinesByJob[jobId] = lines
            }
            return runId
        }
    }

    func tailTaskRuns(jobId: String, limit: Int) throws -> [SessionHarnessTaskRunRecord] {
        sync {
            guard limit > 0 else { return [] }
            let lines = cronLinesByJob[jobId] ?? []
            let tail = lines.suffix(limit)
            let dec = JSONDecoder()
            return tail.compactMap { try? dec.decode(SessionHarnessTaskRunRecord.self, from: $0) }
        }
    }

    func latestUndeliveredTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord? {
        sync {
            guard let idx = pendingTasks.firstIndex(where: { $0.jobId == jobId && !$0.delivered }) else { return nil }
            let t = pendingTasks[idx]
            return SessionHarnessTaskRunRecord(
                runId: t.runId,
                jobId: t.jobId,
                createdAt: t.createdAt,
                payload: t.payload,
                idempotencyKey: t.idempotencyKey
            )
        }
    }

    func markTaskRunDelivered(runId: UUID) throws {
        sync {
            if let idx = pendingTasks.firstIndex(where: { $0.runId == runId }) {
                pendingTasks[idx].delivered = true
            }
        }
    }

    func upsertScheduledTaskDefinition(_ encoded: Data) throws {
        let record: SessionScheduledTaskDefinitionRecord
        do {
            record = try JSONDecoder().decode(SessionScheduledTaskDefinitionRecord.self, from: encoded)
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(
                reason: "scheduled task definition is not valid JSON: \(error.localizedDescription)"
            )
        }
        guard !record.taskId.isEmpty else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "scheduled task taskId is empty")
        }
        sync {
            scheduledDefinitions[record.taskId] = ScheduledDefinition(agentId: record.agentId, payload: encoded)
        }
    }

    func listScheduledTaskDefinitions(agentId: String?) throws -> [Data] {
        sync {
            scheduledDefinitions.keys.sorted().compactMap { taskId in
                guard let def = scheduledDefinitions[taskId] else { return nil }
                if let agentId {
                    guard def.agentId == agentId else { return nil }
                }
                return def.payload
            }
        }
    }

    func getStateMetaValue(key: String) throws -> String? {
        sync { stateMeta[key] }
    }

    func setStateMetaValue(key: String, value: String) throws {
        sync { stateMeta[key] = value }
    }

    func sessionAgentDirectory(agentId: String) throws -> URL {
        let url = SessionPersistenceLayout.agentRootDirectory(root: layoutRoot, agentId: agentId)
        try SessionPersistenceLayout.ensureDirectory(url)
        return url
    }

    func sessionAuthProfile(agentId: String, name: String) throws -> Data? {
        let url = SessionPersistenceLayout.agentAuthProfilesURL(root: layoutRoot, agentId: agentId)
        return try SessionAuthProfilesFile.loadProfile(fromFileAt: url, name: name)
    }

    func listSessionAgentIdentifiers() throws -> [String] {
        let agentsRoot = layoutRoot.appendingPathComponent("agents", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agentsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: agentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )
        return try urls.compactMap { entryURL in
            let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values.isDirectory == true else { return nil }
            guard values.isHidden != true else { return nil }
            let name = entryURL.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            return name
        }
        .sorted()
    }

    func createConversation(_ params: SessionConversationCreationParams) throws -> SessionCatalogRecord {
        let normalized = try params.normalizedForCreate()
        guard normalized.agentId == agentId else {
            throw SessionPersistenceError.unsupportedOperation("createConversation: agentId mismatch")
        }
        let newId = UUID()
        let now = Date()
        let record = normalized.makeCatalogRecord(id: newId, catalogAgentId: agentId, updatedAt: now)
        try sync {
            if catalogs[newId] != nil {
                throw SessionPersistenceError.catalogStoreFailed(operation: "create_session_conversation_exists", sqliteCode: nil)
            }
        }
        try bootstrapEmptyConversation(record)
        return try sync {
            guard let row = catalogs[newId] else {
                throw SessionPersistenceError.catalogStoreFailed(operation: "create_session_conversation_missing_row", sqliteCode: nil)
            }
            return row
        }
    }

    func updateSessionConversation(conversationID: UUID, patch: SessionConversationUpdatePatch, expectedRevision: UInt64?) throws -> SessionCatalogRecord {
        try sync {
            guard var row = catalogs[conversationID] else {
                throw SessionPersistenceError.conversationNotFound(conversationID)
            }
            if let expectedRevision, UInt64(row.controlPlaneRevision) != expectedRevision {
                throw SessionPersistenceError.controlPlaneRevisionConflict(
                    conversationID: conversationID,
                    expectedRevision: expectedRevision,
                    actualRevision: UInt64(row.controlPlaneRevision)
                )
            }
            Self.applySessionUpdatePatch(patch, to: &row)
            row.controlPlaneRevision += 1
            try assertNoDuplicateAgentTitle(forNewTitle: row.title, excludingConversationID: conversationID)
            catalogs[conversationID] = row
            return row
        }
    }

    func resolveSessionByTitle(_ title: String, lifecycleState: String?) throws -> UUID? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let rows = try listCatalogConversations()
        return try SessionTitleResolution.resolveSessionID(records: rows, normalizedTitle: norm, lifecycleState: lifecycleState)
    }

    func nextSessionTitleInLineage(forTitle title: String, lifecycleState: String?) throws -> String? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let rows = try listCatalogConversations()
        return SessionTitleResolution.newestLineageTitle(records: rows, baseTitle: norm, lifecycleState: lifecycleState)
    }

    func resolveLatestSessionIDInLineage(forTitle title: String, lifecycleState: String?) throws -> UUID? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let rows = try listCatalogConversations()
        return SessionTitleResolution.newestLineageRecord(records: rows, baseTitle: norm, lifecycleState: lifecycleState)?.id
    }

    private func assertNoDuplicateAgentTitle(forNewTitle: String?, excludingConversationID: UUID?) throws {
        guard let t = forNewTitle else { return }
        let clash = sync {
            catalogs.values.contains { other in
                other.id != excludingConversationID && other.agentId == agentId && other.title == t
            }
        }
        if clash {
            throw SessionPersistenceError.duplicateCatalogTitle(reason: "duplicate non-null title for agent_id=\(agentId)")
        }
    }

    private static func applySessionUpdatePatch(_ patch: SessionConversationUpdatePatch, to record: inout SessionCatalogRecord) {
        switch patch.topic { case .unchanged: break; case .set(let v): record.topic = SessionTitleResolution.normalizedStoredTitle(v) }
        switch patch.description { case .unchanged: break; case .set(let v): record.description = v }
        switch patch.modelName { case .unchanged: break; case .set(let v): record.modelName = v }
        switch patch.interactionModeRaw { case .unchanged: break; case .set(let v): record.interactionModeRaw = v }
        switch patch.modeProfileID { case .unchanged: break; case .set(let v): record.modeProfileID = v }
        switch patch.source { case .unchanged: break; case .set(let v): record.source = v }
        switch patch.trustClass { case .unchanged: break; case .set(let v): record.trustClass = v }
        switch patch.parentConversationID { case .unchanged: break; case .set(let v): record.parentConversationID = v }
        switch patch.forkAnchorEntryID { case .unchanged: break; case .set(let v): record.forkAnchorEntryID = v }
        switch patch.headEntryId { case .unchanged: break; case .set(let v): record.headEntryId = v }
        switch patch.userID { case .unchanged: break; case .set(let v): record.userID = v }
        switch patch.lifecycleStateRaw { case .unchanged: break; case .set(let v): record.lifecycleStateRaw = v }
        switch patch.title { case .unchanged: break; case .set(let v): record.title = SessionTitleResolution.normalizedStoredTitle(v) }
        switch patch.cwd { case .unchanged: break; case .set(let v): record.cwd = v }
        switch patch.endedAt { case .unchanged: break; case .set(let v): record.endedAt = v }
        switch patch.endReason { case .unchanged: break; case .set(let v): record.endReason = v }
        switch patch.toolCallCount { case .unchanged: break; case .set(let v): record.toolCallCount = v }
        switch patch.totalPromptTokens { case .unchanged: break; case .set(let v): record.totalPromptTokens = v }
        switch patch.totalCompletionTokens { case .unchanged: break; case .set(let v): record.totalCompletionTokens = v }
        switch patch.totalCostMinorUnits { case .unchanged: break; case .set(let v): record.totalCostMinorUnits = v }
        switch patch.modelConfigJSON { case .unchanged: break; case .set(let v): record.modelConfigJSON = v }
        switch patch.reasoningTokens { case .unchanged: break; case .set(let v): record.reasoningTokens = v }
        switch patch.cacheTokens { case .unchanged: break; case .set(let v): record.cacheTokens = v }
        switch patch.firstUserPrompt { case .unchanged: break; case .set(let v): record.firstUserPrompt = v }
        switch patch.updatedAt { case .unchanged: break; case .set(let v): record.updatedAt = v }
        switch patch.resourceJSON { case .unchanged: break; case .set(let v): record.resourceJSON = v }
        switch patch.currentRunID { case .unchanged: break; case .set(let v): record.currentRunID = v }
        switch patch.lastActiveAt { case .unchanged: break; case .set(let v): record.lastActiveAt = v }
        switch patch.resourceRunStatusRaw { case .unchanged: break; case .set(let v): record.resourceRunStatusRaw = v }
        switch patch.metadataJSON { case .unchanged: break; case .set(let v): record.metadataJSON = v }
        switch patch.systemPrompt { case .unchanged: break; case .set(let v): record.systemPrompt = v }
        switch patch.lineageKind { case .unchanged: break; case .set(let v): record.lineageKind = v }
        switch patch.origin { case .unchanged: break; case .set(let v): record.origin = v }
    }
}

private final class InMemoryHarnessSubscribeContext: Sendable {
    let mem: InMemoryHarnessSessionPersistence
    let conversationID: UUID

    init(mem: InMemoryHarnessSessionPersistence, conversationID: UUID) {
        self.mem = mem
        self.conversationID = conversationID
    }

    func read(_ request: SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry] {
        try mem.readTranscriptEntries(conversationID: conversationID, request: request)
    }

    func latest() throws -> Int {
        try mem.latestTranscriptSequence(conversationID: conversationID)
    }
}
