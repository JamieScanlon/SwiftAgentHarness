//
//  Install-wide durable blob reference index (all agent_ids) for reclaim and dangling detection.
//

import Foundation
import SQLite3

enum SessionBlobReferenceScanner {
    private static let danglingSampleCap = 32
    private static let storeAbsentRatioThreshold = 0.5

    static func allReferencedDurableBlobIds(root: URL) throws -> Set<String> {
        Set(try collectReferences(root: root).map(\.blobId))
    }

    static func collectReferences(root: URL) throws -> [SessionCollectedBlobReference] {
        let catalogURL = SessionPersistenceLayout.catalogURL(root: root)
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return [] }
        let reader = try CatalogReader(catalogURL: catalogURL)
        defer { reader.close() }
        return try reader.collectReferences()
    }

    static func danglingDurableBlobReferences(root: URL) throws -> [SessionDanglingBlobReference] {
        try collectReferences(root: root).compactMap { ref in
            guard SessionBlobStore.isValidBlobId(ref.blobId) else { return nil }
            // durableFileExists includes trashed bytes (recoverable via get/put resurrection).
            guard !SessionBlobStore.durableFileExists(root: root, blobId: ref.blobId) else { return nil }
            return SessionDanglingBlobReference(
                blobId: ref.blobId,
                conversationID: ref.conversationID,
                messageSequence: ref.messageSequence,
                source: ref.source
            )
        }
    }

    static func integrityReport(
        root: URL,
        graceSeconds: Int,
        reclaimUnreferenced: Bool,
        now: Date = Date()
    ) throws -> SessionBlobIntegrityReport {
        let live = try allReferencedDurableBlobIds(root: root)
        var trashed = 0
        var hardDeleted = 0
        if reclaimUnreferenced {
            let store = SessionBlobStore(root: root, maxBytes: SessionPersistenceConfiguration.blobMaxBytes)
            let counts = try store.reclaimUnreferencedDurable(
                liveBlobIds: live,
                trashRetentionInterval: TimeInterval(graceSeconds),
                now: now
            )
            trashed = counts.trashed
            hardDeleted = counts.hardDeleted
        }
        let dangling = try danglingDurableBlobReferences(root: root)
        let uniqueDangling = Set(dangling.map(\.blobId))
        let referencedCount = live.count
        let danglingCount = uniqueDangling.count
        let ratio = referencedCount > 0 ? Double(danglingCount) / Double(referencedCount) : 0
        let severity: SessionBlobIntegritySeverity
        if danglingCount == 0 {
            severity = .normal
        } else if ratio > storeAbsentRatioThreshold {
            severity = .storeAbsentSuspected
        } else {
            severity = .elevated
        }
        return SessionBlobIntegrityReport(
            referencedCount: referencedCount,
            danglingCount: danglingCount,
            danglingRatio: ratio,
            severity: severity,
            danglingSamples: Array(dangling.prefix(danglingSampleCap)),
            trashedUnreferencedCount: trashed,
            hardDeletedTrashCount: hardDeleted
        )
    }

    static func normalizeCollectedBlobId(_ raw: String) -> String? {
        let normalized = SessionBlobStore.normalizeBlobId(raw)
        return SessionBlobStore.isValidBlobId(normalized) ? normalized : nil
    }

    static func blobIdsInAttachmentRefsJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let refs = try? JSONDecoder().decode([MessageTranscriptAttachmentWire].self, from: data)
        else { return [] }
        return refs.compactMap { normalizeCollectedBlobId($0.blobId) }
    }

    static func blobIdsInPayloadJSON(_ payloadJSON: String) -> [String] {
        var ids: [String] = []
        if let payload = try? MessageTranscriptPayloadCodec.decode(payloadJSON),
           let refs = payload.attachmentRefs {
            ids.append(contentsOf: refs.compactMap { normalizeCollectedBlobId($0.blobId) })
        }
        ids.append(contentsOf: scanBlobPaths(in: payloadJSON))
        return ids
    }

    private static func scanBlobPaths(in text: String) -> [String] {
        var ids: [String] = []
        let scheme = SessionBlobImageRef.scheme
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: scheme, range: start..<text.endIndex) {
            let hexStart = range.upperBound
            guard let hexEnd = text.index(hexStart, offsetBy: 64, limitedBy: text.endIndex),
                  text.distance(from: hexStart, to: hexEnd) == 64
            else {
                start = range.upperBound
                continue
            }
            if let normalized = normalizeCollectedBlobId(String(text[hexStart..<hexEnd])) {
                ids.append(normalized)
            }
            start = range.upperBound
        }
        return ids
    }

    private final class CatalogReader {
        private var db: OpaquePointer?

        init(catalogURL: URL) throws {
            let rc = sqlite3_open_v2(catalogURL.path, &db, SQLITE_OPEN_READONLY, nil)
            guard rc == SQLITE_OK, db != nil else {
                if let db { sqlite3_close(db) }
                throw SessionPersistenceError.catalogStoreFailed(operation: "blob_reference_scan_open", sqliteCode: Int32(rc))
            }
        }

        func close() {
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }

        func collectReferences() throws -> [SessionCollectedBlobReference] {
            guard let db else { return [] }
            var refs: [SessionCollectedBlobReference] = []
            refs.append(contentsOf: try scanMessageRows(db: db))
            refs.append(contentsOf: try scanConversationRows(db: db))
            return refs
        }

        private func scanMessageRows(db: OpaquePointer) throws -> [SessionCollectedBlobReference] {
            let sql = """
            SELECT conversation_id, sequence, attachment_refs_json, payload_json FROM messages
            WHERE attachment_refs_json IS NOT NULL OR payload_json LIKE '%blob://%' ESCAPE '\\';
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SessionPersistenceError.catalogStoreFailed(operation: "blob_reference_scan_messages", sqliteCode: nil)
            }
            var refs: [SessionCollectedBlobReference] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cidText = sqlite3_column_text(stmt, 0),
                      let conversationID = UUID(uuidString: String(cString: cidText))
                else { continue }
                let sequence = Int(sqlite3_column_int(stmt, 1))
                if let attachmentText = sqlite3_column_text(stmt, 2) {
                    let json = String(cString: attachmentText)
                    for blobId in SessionBlobReferenceScanner.blobIdsInAttachmentRefsJSON(json) {
                        refs.append(
                            SessionCollectedBlobReference(
                                blobId: blobId,
                                conversationID: conversationID,
                                messageSequence: sequence,
                                source: .messageAttachmentRefs
                            )
                        )
                    }
                }
                if let payloadText = sqlite3_column_text(stmt, 3) {
                    let payloadJSON = String(cString: payloadText)
                    for blobId in SessionBlobReferenceScanner.blobIdsInPayloadJSON(payloadJSON) {
                        refs.append(
                            SessionCollectedBlobReference(
                                blobId: blobId,
                                conversationID: conversationID,
                                messageSequence: sequence,
                                source: .messagePayload
                            )
                        )
                    }
                }
            }
            return refs
        }

        private func scanConversationRows(db: OpaquePointer) throws -> [SessionCollectedBlobReference] {
            let sql = "SELECT id, resource_json FROM conversations WHERE resource_json IS NOT NULL;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SessionPersistenceError.catalogStoreFailed(operation: "blob_reference_scan_conversations", sqliteCode: nil)
            }
            var refs: [SessionCollectedBlobReference] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cidText = sqlite3_column_text(stmt, 0),
                      let conversationID = UUID(uuidString: String(cString: cidText)),
                      let resourceText = sqlite3_column_text(stmt, 1)
                else { continue }
                let resourceJSON = String(cString: resourceText)
                guard let payload = SessionCatalogResourceCodec.decode(resourceJSON),
                      let catalog = payload.attachmentsCatalog
                else { continue }
                for entry in catalog {
                    guard let blobId = entry.blobId,
                          let normalized = SessionBlobReferenceScanner.normalizeCollectedBlobId(blobId)
                    else { continue }
                    refs.append(
                        SessionCollectedBlobReference(
                            blobId: normalized,
                            conversationID: conversationID,
                            messageSequence: nil,
                            source: .attachmentsCatalog
                        )
                    )
                }
            }
            return refs
        }
    }
}
