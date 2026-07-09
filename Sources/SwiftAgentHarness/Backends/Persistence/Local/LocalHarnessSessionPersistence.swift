//
//  SQLite catalog + JSONL transcript (harness layout). Process-aware file lock per conversation
//  when multiple OS processes share the store; single-process servers rely on actor-isolated writers.
//

import Foundation
import Logging
import SwiftAgentKit

/// v2 on-disk persistence under a dedicated directory (e.g. Application Support `{host}/session-v2`).
/// `@unchecked Sendable`: confined to ``HarnessRuntimeSession`` + SQLite locking; matches ``InMemoryHarnessSessionPersistence``.
/// Use of @unchecked Sendable is valid here
final class LocalHarnessSessionPersistence: HarnessSessionPersistence, @unchecked Sendable {
    private let root: URL
    private let agentId: String
    private let catalog: SQLiteSessionCatalog
    private let enforceTranscriptWriteLock: Bool
    private let logger: Logger

    /// Install/diagnostics: same directory as ``init(root:agentId:)``.
    var harnessStoreRoot: URL { root }
    /// Install/diagnostics: same `agentId` as ``init(root:agentId:)``.
    var harnessAgentId: String { agentId }

    func catalogSchemaVersion() throws -> Int {
        try withCatalog { try catalog.exposedSchemaVersionForRecoveryIndex() }
    }

    private static let lineageMaxDepthDefault = 256

    init(
        root: URL,
        agentId: String = SessionPersistenceLayout.defaultAgentId,
        logger: Logger? = nil
    ) throws {
        self.root = root
        self.agentId = agentId
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "LocalHarnessSessionPersistence")
        )
        // Snapshot process configuration at construction so tests (and callers) are not affected
        // by concurrent environment mutations while this persistence instance is in use.
        self.enforceTranscriptWriteLock = SessionPersistenceConfiguration.enforceTranscriptWriteLock
        try SessionPersistenceLayout.ensureDirectory(root)
        try SessionPersistenceLayout.ensureDirectory(
            SessionPersistenceLayout.agentSessionsDirectory(root: root, agentId: agentId)
        )
        do {
            self.catalog = try SQLiteSessionCatalog(
                fileURL: SessionPersistenceLayout.catalogURL(root: root),
                agentId: agentId
            )
        } catch let e as SQLiteSessionCatalogError {
            throw SessionCatalogErrorMapping.persistenceError(from: e)
        }
    }

    private func withCatalog<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let e as SQLiteSessionCatalogError {
            logger.error("[LocalHarnessSessionPersistence] SQLite catalog error agent=\(agentId) root=\(root.path) error=\(String(describing: e))")
            throw SessionCatalogErrorMapping.persistenceError(from: e)
        }
    }

    /// Non-blocking WAL hint after large transactional batches (see P4 checkpoint policy).
    func passiveCheckpointCatalog() throws {
        try withCatalog { try catalog.passiveWalCheckpoint() }
    }

    func vacuumCatalog() throws {
        try withCatalog { try catalog.vacuum() }
    }

    private func transcriptLockURL(conversationID: UUID) -> URL {
        SessionPersistenceLayout.transcriptLockURL(root: root, agentId: agentId, conversationId: conversationID)
    }

    /// Creates catalog row + versioned JSONL header (line 1).
    func bootstrapEmptyConversation(_ record: SessionCatalogRecord) throws {
        logger.info("[LocalHarnessSessionPersistence] bootstrap conversation start id=\(record.id) topic=\(record.topic ?? "nil") title=\(record.title ?? "nil")")
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: record.id,
            lockFileURL: transcriptLockURL(conversationID: record.id),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        var row = record
        row.agentId = agentId
        row.messageCount = 0
        let occupied = try withCatalog {
            Set<String>(
                try catalog.fetchCatalogConversations().compactMap { existing in
                    guard existing.id != row.id, let t = existing.title else { return nil }
                    return t
                }
            )
        }
        SessionCatalogTitleDisambiguation.apply(to: &row, occupiedNonNullTitles: occupied)
        logger.info("[LocalHarnessSessionPersistence] bootstrap conversation disambiguated id=\(row.id) topic=\(row.topic ?? "nil") title=\(row.title ?? "nil") occupiedCount=\(occupied.count)")
        try withCatalog { try catalog.insertConversation(row) }
        let transcriptURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: record.id
        )
        let writer = SessionJSONLTranscriptWriter(fileURL: transcriptURL)
        try writer.writeFreshHeader(conversationId: record.id)
        try refreshSessionsRecoveryIndex()
        logger.info("[LocalHarnessSessionPersistence] bootstrap conversation complete id=\(row.id)")
    }

    /// Acquires file lock, then JSONL append + fsync, then catalog row (harness README order).
    func appendTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
    }

    /// Caller must hold the process-aware transcript lock for `conversationID`.
    func appendTranscriptEntryUnlocked(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        try assertTranscriptNotQuarantined(conversationID: conversationID)
        if enforceTranscriptWriteLock,
           !TranscriptWriteLockHeldRegistry.isWriteLockHeld(conversationID: conversationID) {
            throw SessionPersistenceError.lockNotHeld(conversationId: conversationID)
        }
        switch entry.type {
        case .conversationJournal, .derivedJournal:
            _ = try SessionTranscriptPayloadAllowlist.decodeTranscriptJournalEnvelope(entry.payloadJSON)
        default:
            break
        }
        let url = SessionPersistenceLayout.transcriptURL(root: root, agentId: agentId, conversationId: conversationID)
        let writer = SessionJSONLTranscriptWriter(fileURL: url)
        let line: Data
        do {
            line = try SessionJSONLTranscriptCodec.jsonlData(for: entry)
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "jsonl_entry_encode")
        }
        do {
            try writer.appendEntryLine(line)
        } catch let w as SessionJSONLTranscriptWriterError {
            throw SessionCatalogErrorMapping.persistenceError(fromJSONLWriter: w)
        } catch {
            throw SessionCatalogErrorMapping.persistenceError(from: error)
        }
        try withCatalog { try catalog.insertMessage(conversationID: conversationID, entry: entry) }
        if let prompt = SessionTranscriptMapping.inferFirstUserPromptIfNeeded(from: entry) {
            try? withCatalog { try catalog.coalesceFirstUserPrompt(conversationID: conversationID, text: prompt) }
        }
    }

    // MARK: - CatalogPersistence

    func listCatalogConversations() throws -> [SessionCatalogRecord] {
        try withCatalog { try catalog.fetchCatalogConversations() }
    }

    func catalogConversation(id: UUID) throws -> SessionCatalogRecord? {
        try withCatalog { try catalog.fetchCatalogConversation(id: id) }
    }

    func listCatalogConversationsPage(cursor: String?, limit: Int) throws -> SessionCatalogPage {
        try withCatalog { try catalog.fetchCatalogConversationsPage(cursor: cursor, limit: limit) }
    }

    func listConversations(_ filter: SessionConversationListFilter, limit: Int, cursor: String?) throws -> SessionCatalogPage {
        try withCatalog { try catalog.fetchCatalogConversationsFilteredPage(filter: filter, cursor: cursor, limit: limit) }
    }

    func resolveSessionByTitle(_ title: String, lifecycleState: String?) throws -> UUID? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let ids = try withCatalog { try catalog.fetchConversationIDsMatchingExactTitle(title: norm, lifecycleState: lifecycleState, limit: 3) }
        if ids.count > 1 {
            throw SessionPersistenceError.titleAmbiguous(title: norm, lifecycleState: lifecycleState)
        }
        return ids.first
    }

    func nextSessionTitleInLineage(forTitle title: String, lifecycleState: String?) throws -> String? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let rows = try withCatalog { try catalog.fetchCatalogConversations() }
        return SessionTitleResolution.newestLineageTitle(records: rows, baseTitle: norm, lifecycleState: lifecycleState)
    }

    func resolveLatestSessionIDInLineage(forTitle title: String, lifecycleState: String?) throws -> UUID? {
        let norm = SessionTitleResolution.normalizedTitleForLookup(title)
        let rows = try withCatalog { try catalog.fetchCatalogConversations() }
        return SessionTitleResolution.newestLineageRecord(records: rows, baseTitle: norm, lifecycleState: lifecycleState)?.id
    }

    // MARK: - TranscriptPersistence

    /// Reads transcript rows from the SQLite catalog (`fetchMessages` with optional sequence bounds).
    ///
    /// Steady-state: no full JSONL parse. When the transcript file exists, ``reconcileTranscriptCatalogFromJSONLIfDrift(conversationID:jsonlURL:)`` runs first and reparses JSONL only when catalog and file **row counts** diverge; content edits in place without a count change leave the catalog authoritative.
    ///
    /// Throws ``SessionPersistenceError/transcriptCorrupt(conversationID:reason:)`` only when the catalog returns no rows but JSONL is present and fails ``SessionJSONLTranscriptReader/entryLineCount(fileURL:)``. When the catalog is populated (the common case), unparseable JSONL is masked — catalog rows are returned and drift reconcile bails silently on parse failure.
    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry] {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        if let from = request.fromSequence {
            let latest = try latestTranscriptSequence(conversationID: conversationID)
            try TranscriptTailRetentionPolicy.fromEnvironmentOrDefault().requireReplayWindow(
                conversationID: conversationID,
                clientInclusiveFloor: from,
                latestSequence: latest
            )
        }
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        let jsonlMissing = !FileManager.default.fileExists(atPath: jsonlURL.path)
        let isQuarantined = try withCatalog {
            try catalog.fetchTranscriptIntegrity(conversationID: conversationID)?.state == .quarantined
        }
        if !jsonlMissing, !isQuarantined {
            try reconcileTranscriptCatalogFromJSONLIfDrift(conversationID: conversationID, jsonlURL: jsonlURL)
        }
        let fromCatalog = try withCatalog {
            try catalog.fetchMessages(
                conversationID: conversationID,
                fromSequence: request.fromSequence,
                toSequence: request.toSequence
            )
        }
        if fromCatalog.isEmpty && !jsonlMissing {
            do {
                _ = try SessionJSONLTranscriptReader.entryLineCount(fileURL: jsonlURL)
            } catch SessionJSONLTranscriptReaderError.transcriptFileMissing {
                // unreachable when jsonlMissing is false
            } catch {
                throw SessionPersistenceError.transcriptCorrupt(conversationID: conversationID, reason: String(describing: error))
            }
        }
        return SessionJSONLTranscriptReader.filter(entries: fromCatalog, request: request)
    }

    /// Rewrites JSONL from catalog rows under the transcript write lock.
    ///
    /// Recovery path once corruption is detected (e.g. via a full-parse integrity check); does not validate JSONL first.
    func repairTranscriptFromCatalog(conversationID: UUID) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let lock = try acquireTranscriptWriteLock(
            conversationID: conversationID,
            allowReentrant: false,
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs
        )
        defer { lock.unlock() }
        let entries = try withCatalog {
            try catalog.fetchMessages(conversationID: conversationID, fromSequence: nil)
        }
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let cwd = try withCatalog { try catalog.fetchCatalogConversation(id: conversationID)?.cwd }
        let header = SessionJSONLHeader(
            version: SessionJSONLTranscriptFormat.currentWriteHeaderVersion,
            id: conversationID.uuidString,
            timestamp: iso.string(from: Date()),
            cwd: cwd
        )
        try SessionJSONLTranscriptWriter.rewriteTranscript(
            fileURL: jsonlURL,
            parsed: ParsedTranscriptFile(header: header, entries: entries)
        )
    }

    func verifyTranscript(conversationID: UUID) throws -> TranscriptVerifyReport {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let catalogLatest = try latestTranscriptSequence(conversationID: conversationID)
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        let scan = try SessionJSONLTranscriptReader.verifyLineScan(
            fileURL: jsonlURL,
            catalogLatestSequence: catalogLatest
        )
        let isTailConfined = scan.damageClass == .tailConfined
        let isLosslesslyRepairable = isTailConfined && catalogLatest >= scan.lastCleanJSONLSequence
        return TranscriptVerifyReport(
            conversationID: conversationID,
            catalogLatestSequence: catalogLatest,
            lastCleanJSONLSequence: scan.lastCleanJSONLSequence,
            isTailConfined: isTailConfined,
            isLosslesslyRepairable: isLosslesslyRepairable,
            damageClass: scan.damageClass,
            reason: scan.reason,
            maintenanceAction: .none
        )
    }

    func autoRepairTranscriptIfLossless(conversationID: UUID, report: TranscriptVerifyReport, now: Date = Date()) throws {
        guard report.isLosslesslyRepairable else { return }
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        _ = try SessionJSONLTranscriptWriter.sideCopyCorruptTranscript(fileURL: jsonlURL, now: now)
        try repairTranscriptFromCatalog(conversationID: conversationID)
    }

    func quarantineTranscript(conversationID: UUID, reason: String) throws {
        try withCatalog {
            try catalog.setTranscriptIntegrity(
                conversationID: conversationID,
                integrity: SessionTranscriptIntegrity(state: .quarantined, reason: reason)
            )
        }
    }

    func repairQuarantinedTranscript(conversationID: UUID, now: Date = Date()) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let integrity = try withCatalog { try catalog.fetchTranscriptIntegrity(conversationID: conversationID) }
        guard integrity?.state == .quarantined else {
            throw SessionPersistenceError.unsupportedOperation("transcript not quarantined")
        }
        let beforeCount = try withCatalog { try catalog.transcriptRowCount(conversationID: conversationID) }
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        if FileManager.default.fileExists(atPath: jsonlURL.path) {
            let dir = jsonlURL.deletingLastPathComponent()
            let prefix = jsonlURL.deletingPathExtension().lastPathComponent + ".jsonl.corrupt-"
            let hasCopy = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .contains { $0.lastPathComponent.hasPrefix(prefix) } ?? false
            if !hasCopy {
                _ = try SessionJSONLTranscriptWriter.sideCopyCorruptTranscript(fileURL: jsonlURL, now: now)
            }
        }
        try repairTranscriptFromCatalog(conversationID: conversationID)
        let afterCount = try withCatalog { try catalog.transcriptRowCount(conversationID: conversationID) }
        logger.info(
            "[LocalHarnessSessionPersistence] repairQuarantinedTranscript id=\(conversationID) rowsBefore=\(beforeCount) rowsAfter=\(afterCount)"
        )
        try withCatalog { try catalog.setTranscriptIntegrity(conversationID: conversationID, integrity: nil) }
    }

    private func assertTranscriptNotQuarantined(conversationID: UUID) throws {
        if let integrity = try withCatalog({ try catalog.fetchTranscriptIntegrity(conversationID: conversationID) }),
           integrity.state == .quarantined {
            throw SessionPersistenceError.transcriptQuarantined(
                conversationID: conversationID,
                reason: integrity.reason ?? "transcript quarantined"
            )
        }
    }

    /// Backfills missing catalog rows from a full JSONL parse. JSONL is authoritative on this path (typically after count drift).
    func reconcileTranscriptCatalogFromJSONL(conversationID: UUID) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let jsonlURL = SessionPersistenceLayout.transcriptURL(
            root: root,
            agentId: agentId,
            conversationId: conversationID
        )
        let fromFile: [SessionTranscriptEntry]
        do {
            fromFile = try SessionJSONLTranscriptReader.loadEntries(fileURL: jsonlURL)
        } catch SessionJSONLTranscriptReaderError.transcriptFileMissing {
            return
        } catch {
            throw SessionPersistenceError.transcriptCorrupt(conversationID: conversationID, reason: String(describing: error))
        }
        try withCatalog {
            try catalog.reconcileMissingRows(conversationID: conversationID, authoritativeEntries: fromFile)
        }
    }

    /// Compares catalog vs JSONL entry line counts; calls ``reconcileTranscriptCatalogFromJSONL(conversationID:)`` only when they differ (count-accurate, not byte-accurate).
    ///
    /// Uses `try?` on ``SessionJSONLTranscriptReader/entryLineCount(fileURL:)`` — header/UTF-8 failures skip drift reconcile rather than surfacing ``SessionPersistenceError/transcriptCorrupt(conversationID:reason:)`` on the read hot path.
    private func reconcileTranscriptCatalogFromJSONLIfDrift(conversationID: UUID, jsonlURL: URL) throws {
        guard let jsonlCount = try? SessionJSONLTranscriptReader.entryLineCount(fileURL: jsonlURL), jsonlCount > 0 else {
            return
        }
        let catalogCount = try withCatalog { try catalog.transcriptRowCount(conversationID: conversationID) }
        guard catalogCount != jsonlCount else { return }
        try reconcileTranscriptCatalogFromJSONL(conversationID: conversationID)
    }

    private func fetchCatalogTranscriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry? {
        try withCatalog { try catalog.fetchTranscriptEntry(conversationID: conversationID, entryId: entryId) }
    }

    func latestTranscriptSequence(conversationID: UUID) throws -> Int {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return try withCatalog { try catalog.latestSequence(conversationID: conversationID) }
    }

    func subscribeTranscript(conversationID: UUID, fromSequence: Int) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        let box = LocalHarnessSubscribeContext(local: self, conversationID: conversationID)
        return TranscriptSubscriptionStream.entryEvents(
            conversationID: conversationID,
            inclusiveFrom: fromSequence,
            retention: TranscriptTailRetentionPolicy.fromEnvironmentOrDefault(),
            pollInterval: TranscriptSubscriptionStream.pollIntervalFromEnvironmentOrDefault(),
            preferredTailStrategy: SessionPersistenceConfiguration.transcriptSubscribeTailStrategy,
            readEntries: { try box.read($0) },
            latestSequence: { try box.latest() }
        )
    }

    // MARK: - HarnessSessionPersistence

    func acquireTranscriptWriteLock(conversationID: UUID, allowReentrant: Bool, timeoutMs: Int) throws -> any TranscriptWriteLock {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: timeoutMs,
            allowReentrant: allowReentrant
        )
    }

    func appendMirroredTranscriptEntry(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
    }

    func rollBackLastMirroredTranscriptAppend(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let url = SessionPersistenceLayout.transcriptURL(root: root, agentId: agentId, conversationId: conversationID)
        guard try withCatalog({ try catalog.latestSequence(conversationID: conversationID) }) == entry.sequence else { return }
        try withCatalog {
            try catalog.deleteTailMessage(
                conversationID: conversationID,
                sequence: entry.sequence,
                entryId: entry.entryId,
                rollbackTimestamp: Date(),
                shouldDecrementCatalogMessageCount: entry.type.countsTowardSessionCatalogMessageTotal
            )
        }
        do {
            try SessionJSONLTranscriptWriter.truncateLastEntryLine(fileURL: url)
        } catch let w as SessionJSONLTranscriptWriterError {
            throw SessionCatalogErrorMapping.persistenceError(fromJSONLWriter: w)
        } catch {
            throw SessionCatalogErrorMapping.persistenceError(from: error)
        }
    }

    func nextTranscriptSequence(conversationID: UUID) throws -> Int {
        try withCatalog { try catalog.nextSequence(conversationID: conversationID) }
    }

    func transcriptFileURL(conversationID: UUID) -> URL {
        SessionPersistenceLayout.transcriptURL(root: root, agentId: agentId, conversationId: conversationID)
    }

    func updateTranscriptEntryPayload(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let url = transcriptFileURL(conversationID: conversationID)
        let replacePayload = {
            try SessionJSONLTranscriptWriter.replaceBodyEntry(
                fileURL: url,
                conversationID: conversationID,
                entryId: entry.entryId,
                entry: entry
            )
        }
        let apply = {
            try replacePayload()
            try self.syncTranscriptEntryCatalogPayload(conversationID: conversationID, entry: entry)
        }
        if TranscriptWriteLockHeldRegistry.isWriteLockHeld(conversationID: conversationID)
            || ProcessAwareTranscriptWriteLock.isHeldOnCurrentThread(conversationID: conversationID) {
            try apply()
            return
        }
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        try apply()
    }

    private func syncTranscriptEntryCatalogPayload(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        try withCatalog {
            try catalog.updateMessageRichPayload(conversationID: conversationID, sequence: entry.sequence, entry: entry)
        }
        try passiveCheckpointCatalog()
    }

    // MARK: - P1

    func applyConversationLifecycle(conversationID: UUID, lifecycle: ConversationLifecycleState) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        try withCatalog {
            try catalog.applyCatalogLifecycle(
                conversationID: conversationID,
                lifecycleStateRaw: lifecycle.rawValue,
                endedAt: nil,
                endReason: nil
            )
        }
    }

    func endConversation(conversationID: UUID, reason: String?) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        try withCatalog {
            try catalog.applyCatalogLifecycle(
                conversationID: conversationID,
                lifecycleStateRaw: ConversationLifecycleState.archived.rawValue,
                endedAt: Date(),
                endReason: reason
            )
        }
    }

    func removeSessionConversation(conversationID: UUID) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        let url = transcriptFileURL(conversationID: conversationID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try withCatalog { try catalog.removeCatalogConversation(conversationID: conversationID) }
        try? evictEngineArtifacts(conversationID: conversationID, key: nil)
        TranscriptJournalTailCache.invalidate(conversationID: conversationID)
        try passiveCheckpointCatalog()
    }

    func reopenConversation(conversationID: UUID) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        try withCatalog { try catalog.reopenCatalogConversation(conversationID: conversationID) }
    }

    func applyConversationTitle(conversationID: UUID, title: String, expectedControlPlaneRevision: UInt64) throws {
        guard let current = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let expectedInt = Int(clamping: expectedControlPlaneRevision)
        guard current.controlPlaneRevision == expectedInt else {
            throw SessionPersistenceError.controlPlaneRevisionConflict(
                conversationID: conversationID,
                expectedRevision: expectedControlPlaneRevision,
                actualRevision: UInt64(current.controlPlaneRevision)
            )
        }
        let sanitized = SessionTitleResolution.sanitizedTitle(title)
        let ok = try withCatalog {
            try catalog.applyCatalogTitle(
                conversationID: conversationID,
                title: sanitized,
                expectedControlPlaneRevision: expectedInt,
                newRevision: expectedInt + 1
            )
        }
        if !ok {
            throw SessionPersistenceError.controlPlaneRevisionConflict(
                conversationID: conversationID,
                expectedRevision: expectedControlPlaneRevision,
                actualRevision: UInt64(current.controlPlaneRevision)
            )
        }
    }

    func transcriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        guard let e = try fetchCatalogTranscriptEntry(conversationID: conversationID, entryId: entryId) else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
        }
        return e
    }

    func childTranscriptEntries(conversationID: UUID, parentEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return try withCatalog { try catalog.fetchChildTranscriptEntries(conversationID: conversationID, parentEntryId: parentEntryId) }
    }

    func transcriptLineage(conversationID: UUID, entryId: SessionEntryID, maxDepth: Int) throws -> [SessionTranscriptEntry] {
        try readLineage(conversationID: conversationID, leafEntryId: entryId).reversed()
    }

    func readLineage(conversationID: UUID, leafEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        guard try fetchCatalogTranscriptEntry(conversationID: conversationID, entryId: leafEntryId) != nil else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: leafEntryId)
        }
        return try SessionTranscriptLineage.readLineageRootToLeaf(
            leafEntryId: leafEntryId,
            fetchEntry: { try self.fetchCatalogTranscriptEntry(conversationID: conversationID, entryId: $0) },
            maxDepth: Self.lineageMaxDepthDefault
        )
    }

    func activeHeadEntryId(conversationID: UUID) throws -> SessionEntryID? {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return try withCatalog { try catalog.fetchCatalogConversation(id: conversationID)?.headEntryId }
    }

    func setActiveHeadEntryId(
        conversationID: UUID,
        entryId: SessionEntryID,
        expectedRevision: UInt64?
    ) throws -> SessionCatalogRecord {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        guard try withCatalog({ try catalog.fetchTranscriptEntry(conversationID: conversationID, entryId: entryId) }) != nil else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
        }
        guard let current = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        if let head = current.headEntryId {
            guard try SessionTranscriptLineage.isAncestorOrSelf(
                candidate: entryId,
                headEntryId: head,
                fetchEntry: { try self.fetchCatalogTranscriptEntry(conversationID: conversationID, entryId: $0) },
                maxDepth: Self.lineageMaxDepthDefault
            ) else {
                throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
            }
        }
        if let expectedRevision {
            guard UInt64(current.controlPlaneRevision) == expectedRevision else {
                throw SessionPersistenceError.controlPlaneRevisionConflict(
                    conversationID: conversationID,
                    expectedRevision: expectedRevision,
                    actualRevision: UInt64(current.controlPlaneRevision)
                )
            }
        }
        let expectedControlPlaneRevision = expectedRevision.map { Int($0) } ?? current.controlPlaneRevision
        let ok = try withCatalog {
            try catalog.setConversationHeadEntryId(
                conversationID: conversationID,
                entryId: entryId,
                expectedControlPlaneRevision: expectedRevision == nil ? nil : expectedControlPlaneRevision
            )
        }
        if expectedRevision != nil, !ok {
            throw SessionPersistenceError.controlPlaneRevisionConflict(
                conversationID: conversationID,
                expectedRevision: expectedRevision!,
                actualRevision: UInt64(current.controlPlaneRevision)
            )
        }
        guard let updated = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return updated
    }

    /// Sets catalog `head_entry_id` without transcript validation (repair / tests).
    func forceActiveHeadEntryId(conversationID: UUID, entryId: SessionEntryID) throws -> SessionCatalogRecord {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        guard try withCatalog({ try catalog.fetchTranscriptEntry(conversationID: conversationID, entryId: entryId) }) != nil else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
        }
        _ = try withCatalog {
            try catalog.setConversationHeadEntryId(
                conversationID: conversationID,
                entryId: entryId,
                expectedControlPlaneRevision: nil
            )
        }
        guard let updated = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return updated
    }

    func appendTranscriptEntries(conversationID: UUID, entries: [SessionTranscriptEntry]) throws {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        try assertTranscriptNotQuarantined(conversationID: conversationID)
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        for e in entries {
            let seq = try withCatalog { try catalog.nextSequence(conversationID: conversationID) }
            var next = e
            next.sequence = seq
            try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: next)
        }
        try passiveCheckpointCatalog()
    }

    func forkConversation(
        parentConversationID: UUID,
        atEntryId: SessionEntryID,
        newConversationId: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil
    ) throws -> SessionCatalogRecord {
        logger.info("[LocalHarnessSessionPersistence] fork start parent=\(parentConversationID) anchor=\(atEntryId.rawValue) child=\(newConversationId) requestedTitle=\(title ?? "nil")")
        guard try withCatalog({ try catalog.conversationExists(id: parentConversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(parentConversationID)
        }
        guard let base = try withCatalog({ try catalog.fetchCatalogConversation(id: parentConversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(parentConversationID)
        }
        let parentEntries = try readTranscriptEntries(conversationID: parentConversationID, request: .full)
        guard parentEntries.contains(where: { $0.entryId == atEntryId }) else {
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
        logger.info("[LocalHarnessSessionPersistence] fork child normalized child=\(newConversationId) normalizedTitle=\(child.title ?? "nil") prefixCount=\(prefix.count)")
        try bootstrapEmptyConversation(child)
        logger.info("[LocalHarnessSessionPersistence] fork child bootstrap complete child=\(newConversationId)")
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
        logger.info("[LocalHarnessSessionPersistence] fork child transcript copy complete child=\(newConversationId) copiedEntries=\(transcriptPrefix.count)")
        guard let row = try catalogConversation(id: newConversationId) else {
            throw SessionPersistenceError.catalogStoreFailed(operation: "fork_missing_child_row", sqliteCode: nil)
        }
        logger.info("[LocalHarnessSessionPersistence] fork complete parent=\(parentConversationID) child=\(newConversationId) finalTitle=\(row.title ?? "nil")")
        return row
    }

    func childConversations(parentConversationID: UUID) throws -> [SessionCatalogRecord] {
        try withCatalog { try catalog.fetchChildConversationRecords(parentID: parentConversationID) }
    }

    func recordTranscriptCompactionEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = try SessionTranscriptPayloadAllowlist.decodeCompactionCheckpointPayload(payloadJSON)
        return try recordAuxTranscriptEntry(conversationID: conversationID, type: .compaction, payloadJSON: payloadJSON)
    }

    func recordTranscriptBranchSummaryEntry(conversationID: UUID, payloadJSON: String) throws -> Int {
        _ = try SessionTranscriptPayloadAllowlist.decodeBranchSummaryPayload(payloadJSON)
        return try recordAuxTranscriptEntry(conversationID: conversationID, type: .branchSummary, payloadJSON: payloadJSON)
    }

    func appendRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        let json = try payload.encodedJSONString()
        try SessionTranscriptPayloadAllowlist.assertRunLifecycleMarkerPayloadAllowed(json)
        try recordCustomHarnessTranscriptEntry(
            conversationID: conversationID,
            harnessTypeRaw: payload.customType,
            payloadJSON: json
        )
    }

    private func recordCustomHarnessTranscriptEntry(conversationID: UUID, harnessTypeRaw: String, payloadJSON: String) throws {
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        let seq = try withCatalog { try catalog.nextSequence(conversationID: conversationID) }
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: nil,
            type: .custom,
            harnessTypeRaw: harnessTypeRaw,
            timestamp: Date(),
            payloadJSON: payloadJSON
        )
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
    }

    private func recordAuxTranscriptEntry(conversationID: UUID, type: SessionTranscriptEntryType, payloadJSON: String) throws -> Int {
        let lock = try ProcessAwareTranscriptWriteLock.acquireExclusive(
            conversationID: conversationID,
            lockFileURL: transcriptLockURL(conversationID: conversationID),
            timeoutMs: SessionPersistenceConfiguration.transcriptLockAcquireTimeoutMs,
            allowReentrant: false
        )
        defer { lock.unlock() }
        let seq = try withCatalog { try catalog.nextSequence(conversationID: conversationID) }
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: nil,
            type: type,
            timestamp: Date(),
            payloadJSON: payloadJSON
        )
        try appendTranscriptEntryUnlocked(conversationID: conversationID, entry: entry)
        return seq
    }

    func searchTranscriptMessages(query: String, agentId: String?, conversationID: UUID?, limit: Int) throws -> [SessionMessageSearchHit] {
        if limit <= 0 { return [] }
        let match = FTS5QuerySanitizer.matchAndPhrases(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if match.isEmpty { return [] }
        return try withCatalog {
            try catalog.searchTranscriptMessages(
                matchSQL: match,
                agentId: agentId,
                conversationID: conversationID,
                limit: limit
            )
        }
    }

    func firstUserPromptText(conversationID: UUID) throws -> String? {
        guard try withCatalog({ try catalog.conversationExists(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        return try withCatalog { try catalog.fetchFirstUserPrompt(conversationID: conversationID) }
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) throws -> Bool {
        do {
            return try dedupeStore().dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
        } catch let e as SessionSQLiteStoreError {
            throw SessionCatalogErrorMapping.persistenceError(from: e)
        }
    }

    func dedupePeek(key: String) throws -> Bool {
        do {
            return try dedupeStore().dedupePeek(key: key)
        } catch let e as SessionSQLiteStoreError {
            throw SessionCatalogErrorMapping.persistenceError(from: e)
        }
    }

    func getEngineArtifact(conversationID: UUID, key: String) throws -> Data? {
        engineArtifactStore().get(conversationId: conversationID, key: key)
    }

    func putEngineArtifact(conversationID: UUID, key: String, data: Data) throws {
        try engineArtifactStore().put(conversationId: conversationID, key: key, data: data)
    }

    func evictEngineArtifacts(conversationID: UUID, key: String?) throws {
        try engineArtifactStore().evict(conversationId: conversationID, key: key)
    }

    func listEngineArtifactKeys(conversationID: UUID) throws -> [String] {
        let dir = SessionPersistenceLayout.engineArtifactsDirectory(root: root, conversationId: conversationID)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    func toolResultSpillDirectory(conversationID: UUID) -> URL? {
        toolResultSpillStore().spillDirectoryURL(conversationId: conversationID)
    }

    func putToolResultSpillIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult? {
        try toolResultSpillStore().putIfNeeded(
            conversationId: conversationID,
            toolCallId: toolCallId,
            content: content
        )
    }

    func isAllowlistedToolResultSpillPath(_ path: String, conversationID: UUID) -> Bool {
        toolResultSpillStore().isAllowlistedSpillPath(path, conversationId: conversationID)
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
        try blobStore().put(
            data: data,
            durability: durability,
            originalName: originalName,
            mimeTypeHint: mimeType,
            trust: trust,
            ttlSeconds: ttlSeconds,
            lane: lane
        )
    }

    func putBlobFromURL(
        url: URL,
        durability: SessionBlobDurability,
        trust: String,
        ttlSeconds: Int?,
        maxBytes: Int?,
        lane: SessionBlobEphemeralLane
    ) throws -> SessionBlobRef {
        try blobStore().putFromURL(
            url: url,
            durability: durability,
            trust: trust,
            ttlSeconds: ttlSeconds,
            maxBytes: maxBytes,
            lane: lane
        )
    }

    func getBlob(blobId: String) throws -> Data {
        try blobStore().get(blobId: blobId)
    }

    func statBlob(blobId: String) throws -> SessionBlobRef {
        try blobStore().stat(blobId: blobId)
    }

    func blobPath(blobId: String) throws -> URL? {
        try blobStore().blobPath(blobId: blobId)
    }

    func promoteBlob(blobId: String) throws -> SessionBlobRef {
        try blobStore().promote(blobId: blobId)
    }

    func deleteBlob(blobId: String) throws {
        try blobStore().delete(blobId: SessionBlobStore.normalizeBlobId(blobId))
    }

    func sweepExpiredBlobs() throws -> Int {
        try blobStore().sweepExpired(now: Date())
    }

    func reclaimUnreferencedDurableBlobs(liveBlobIds: Set<String>, trashRetentionSeconds: Int) throws -> SessionBlobReclaimCounts {
        try blobStore().reclaimUnreferencedDurable(
            liveBlobIds: liveBlobIds,
            trashRetentionInterval: TimeInterval(trashRetentionSeconds)
        )
    }

    func openReferencedDurableBlob(blobId: String, conversationID: UUID?) throws -> Data {
        let normalized = SessionBlobStore.normalizeBlobId(blobId)
        do {
            return try getBlob(blobId: normalized)
        } catch SessionPersistenceError.blobNotFound {
            throw SessionPersistenceError.durableBlobMissing(blobId: normalized, conversationID: conversationID)
        }
    }

    // MARK: - P3c Tasks + cron JSONL

    func appendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) throws -> UUID {
        if let idempotencyKey {
            if let existing = try withCatalog({ try catalog.fetchHarnessTaskRunByIdempotencyKey(idempotencyKey) }) {
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
        let record = SessionHarnessTaskRunRecord(
            runId: runId,
            jobId: jobId,
            createdAt: Date(),
            payload: payload,
            idempotencyKey: idempotencyKey
        )
        let line = try JSONEncoder().encode(record)
        try SessionCronRunStore.append(root: root, jobId: jobId, lineJSON: line)
        do {
            try withCatalog {
                try catalog.insertHarnessTaskPending(
                    jobId: jobId,
                    runId: runId,
                    payload: payload,
                    idempotencyKey: idempotencyKey
                )
            }
        } catch {
            if let idempotencyKey,
               let existing = try? withCatalog({ try catalog.fetchHarnessTaskRunByIdempotencyKey(idempotencyKey) }) {
                if existing.jobId != jobId || existing.payload != payload {
                    throw SessionPersistenceError.idempotencyHit(
                        idempotencyKey: idempotencyKey,
                        existingRunId: existing.runId
                    )
                }
                return existing.runId
            }
            throw SessionCatalogErrorMapping.persistenceError(from: error)
        }
        return runId
    }

    func tailTaskRuns(jobId: String, limit: Int) throws -> [SessionHarnessTaskRunRecord] {
        try SessionCronRunStore.tail(root: root, jobId: jobId, limit: limit)
    }

    func latestUndeliveredTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord? {
        try withCatalog { try catalog.fetchLatestPendingHarnessTaskRun(jobId: jobId) }
    }

    func markTaskRunDelivered(runId: UUID) throws {
        try withCatalog { try catalog.markHarnessTaskDelivered(runId: runId) }
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
        try withCatalog {
            try catalog.upsertScheduledTaskDefinitionRow(taskId: record.taskId, agentId: record.agentId, payload: encoded)
        }
    }

    func listScheduledTaskDefinitions(agentId: String?) throws -> [Data] {
        try withCatalog { try catalog.fetchScheduledTaskDefinitionPayloads(agentId: agentId) }
    }

    func getStateMetaValue(key: String) throws -> String? {
        try withCatalog { try catalog.fetchStateMeta(key: key) }
    }

    func setStateMetaValue(key: String, value: String) throws {
        try withCatalog { try catalog.upsertStateMeta(key: key, value: value) }
    }

    // MARK: - README SessionBackend

    func createConversation(_ params: SessionConversationCreationParams) throws -> SessionCatalogRecord {
        let normalized = try params.normalizedForCreate()
        guard normalized.agentId == agentId else {
            throw SessionPersistenceError.unsupportedOperation("createConversation: agentId mismatch")
        }
        let newId = UUID()
        let now = Date()
        let record = normalized.makeCatalogRecord(id: newId, catalogAgentId: agentId, updatedAt: now)
        if try withCatalog({ try catalog.fetchCatalogConversation(id: newId) }) != nil {
            throw SessionPersistenceError.catalogStoreFailed(operation: "create_session_conversation_exists", sqliteCode: nil)
        }
        try bootstrapEmptyConversation(record)
        guard let created = try catalogConversation(id: newId) else {
            throw SessionPersistenceError.catalogStoreFailed(operation: "create_session_conversation_missing_row", sqliteCode: nil)
        }
        return created
    }

    func updateSessionConversation(conversationID: UUID, patch: SessionConversationUpdatePatch, expectedRevision: UInt64?) throws -> SessionCatalogRecord {
        logger.info("[LocalHarnessSessionPersistence] updateSessionConversation start conversationID=\(conversationID) expectedRevision=\(expectedRevision?.description ?? "nil")")
        guard var current = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        logger.info("[LocalHarnessSessionPersistence] updateSessionConversation current conversationID=\(conversationID) currentTitle=\(current.title ?? "nil") currentTopic=\(current.topic ?? "nil") currentControlPlaneRevision=\(current.controlPlaneRevision)")
        let expected = expectedRevision.map { Int(clamping: $0) }
        if let expected, expected != current.controlPlaneRevision {
            throw SessionPersistenceError.controlPlaneRevisionConflict(
                conversationID: conversationID,
                expectedRevision: UInt64(expected),
                actualRevision: UInt64(current.controlPlaneRevision)
            )
        }
        Self.applySessionUpdatePatch(patch, to: &current)
        logger.info("[LocalHarnessSessionPersistence] updateSessionConversation patched conversationID=\(conversationID) newTitle=\(current.title ?? "nil") newTopic=\(current.topic ?? "nil")")
        if let expected {
            current.controlPlaneRevision = expected + 1
        } else {
            current.controlPlaneRevision += 1
        }
        logger.info("[LocalHarnessSessionPersistence] updateSessionConversation write conversationID=\(conversationID) writeControlPlaneRevision=\(current.controlPlaneRevision)")
        let didUpdate = try withCatalog {
            try catalog.updateCatalogConversationRecord(current, expectedControlPlaneRevision: expected)
        }
        if !didUpdate {
            throw SessionPersistenceError.controlPlaneRevisionConflict(
                conversationID: conversationID,
                expectedRevision: expectedRevision ?? UInt64(current.controlPlaneRevision),
                actualRevision: expectedRevision
            )
        }
        guard let updated = try withCatalog({ try catalog.fetchCatalogConversation(id: conversationID) }) else {
            throw SessionPersistenceError.catalogStoreFailed(operation: "update_session_conversation_missing_row", sqliteCode: nil)
        }
        return updated
    }

    func sessionAgentDirectory(agentId: String) throws -> URL {
        let url = SessionPersistenceLayout.agentRootDirectory(root: root, agentId: agentId)
        try SessionPersistenceLayout.ensureDirectory(url)
        return url
    }

    func sessionAuthProfile(agentId: String, name: String) throws -> Data? {
        let url = SessionPersistenceLayout.agentAuthProfilesURL(root: root, agentId: agentId)
        return try SessionAuthProfilesFile.loadProfile(fromFileAt: url, name: name)
    }

    func listSessionAgentIdentifiers() throws -> [String] {
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
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

    private func refreshSessionsRecoveryIndex() throws {
        let ids = try withCatalog { try catalog.fetchCatalogConversations().map(\.id) }
        let ver = (try? withCatalog { try catalog.exposedSchemaVersionForRecoveryIndex() }) ?? 0
        try SessionPersistenceRecoveryIndexWriter.writeSessionsRecoveryIndex(
            root: root,
            agentId: agentId,
            authProfileLabel: SessionPersistenceConfiguration.sessionAuthProfileLabel,
            catalogSchemaVersion: ver,
            conversationIds: ids
        )
    }

    // MARK: - Adjacent stores (spec)

    func engineArtifactStore() -> SessionEngineArtifactStore {
        SessionEngineArtifactStore(root: root)
    }

    func toolResultSpillStore() -> SessionToolResultSpillStore {
        SessionToolResultSpillStore(root: root, agentId: agentId)
    }

    func blobStore() -> SessionBlobStore {
        SessionBlobStore(root: root, maxBytes: SessionPersistenceConfiguration.blobMaxBytes)
    }

    func dedupeStore() throws -> SessionDedupeSQLiteStore {
        try SessionDedupeSQLiteStore(fileURL: SessionPersistenceLayout.dedupeStoreURL(root: root))
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

private final class LocalHarnessSubscribeContext: Sendable {
    let local: LocalHarnessSessionPersistence
    let conversationID: UUID

    init(local: LocalHarnessSessionPersistence, conversationID: UUID) {
        self.local = local
        self.conversationID = conversationID
    }

    func read(_ request: SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry] {
        try local.readTranscriptEntries(conversationID: conversationID, request: request)
    }

    func latest() throws -> Int {
        try local.latestTranscriptSequence(conversationID: conversationID)
    }
}
