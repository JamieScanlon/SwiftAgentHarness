//
//  Install-wide transcript verify / auto-repair / quarantine at boot and periodic sweeps.
//

import Foundation
import Logging
import SQLite3

enum SessionTranscriptIntegrityScanner {
    private static let sampleCap = 32
    private static let damagedRatioThreshold = 0.5

    static func runTranscriptIntegrityMaintenance(
        root: URL,
        verifyAndRepair: Bool,
        logger: Logger? = nil,
        now: Date = Date()
    ) throws -> SessionTranscriptIntegrityReport {
        try integrityReport(root: root, verifyAndRepair: verifyAndRepair, now: now, logger: logger)
    }

    static func integrityReport(
        root: URL,
        verifyAndRepair: Bool,
        now: Date = Date(),
        logger: Logger? = nil
    ) throws -> SessionTranscriptIntegrityReport {
        let rows = try InstallCatalogReader(root: root).listConversationRows()
        var autoRepaired = 0
        var quarantined = 0
        var verifyFailed = 0
        var samples: [TranscriptVerifyReport] = []

        var storesByAgent: [String: LocalHarnessSessionPersistence] = [:]
        func local(for agentId: String) throws -> LocalHarnessSessionPersistence {
            if let existing = storesByAgent[agentId] { return existing }
            let created = try LocalHarnessSessionPersistence(root: root, agentId: agentId, logger: logger)
            storesByAgent[agentId] = created
            return created
        }

        for row in rows {
            var sample: TranscriptVerifyReport
            do {
                let local = try local(for: row.agentId)
                sample = try local.verifyTranscript(conversationID: row.conversationID)
            } catch {
                verifyFailed += 1
                sample = TranscriptVerifyReport(
                    conversationID: row.conversationID,
                    catalogLatestSequence: 0,
                    lastCleanJSONLSequence: 0,
                    isTailConfined: false,
                    isLosslesslyRepairable: false,
                    damageClass: .structural,
                    reason: String(describing: error),
                    maintenanceAction: .verifyFailed
                )
                if samples.count < sampleCap { samples.append(sample) }
                continue
            }

            guard sample.damageClass != .clean else { continue }

            if !verifyAndRepair {
                if samples.count < sampleCap { samples.append(sample) }
                continue
            }

            if sample.isLosslesslyRepairable {
                do {
                    let local = try local(for: row.agentId)
                    try local.autoRepairTranscriptIfLossless(conversationID: row.conversationID, report: sample, now: now)
                    autoRepaired += 1
                    var repaired = sample
                    repaired.maintenanceAction = .autoRepaired
                    if samples.count < sampleCap { samples.append(repaired) }
                    logger?.info(
                        "SAH_SESSION_TRANSCRIPT_INTEGRITY autoRepaired conversation=\(row.conversationID) lastClean=\(sample.lastCleanJSONLSequence) catalogLatest=\(sample.catalogLatestSequence)"
                    )
                } catch {
                    verifyFailed += 1
                    var failed = sample
                    failed.maintenanceAction = .verifyFailed
                    failed.reason = String(describing: error)
                    if samples.count < sampleCap { samples.append(failed) }
                }
                continue
            }

            let reason = sample.reason ?? sample.damageClass.rawValue
            do {
                let local = try local(for: row.agentId)
                try local.quarantineTranscript(conversationID: row.conversationID, reason: reason)
                quarantined += 1
                var q = sample
                q.maintenanceAction = .quarantined
                if samples.count < sampleCap { samples.append(q) }
                logger?.warning(
                    "SAH_SESSION_TRANSCRIPT_INTEGRITY quarantined conversation=\(row.conversationID) reason=\(reason)"
                )
            } catch {
                verifyFailed += 1
                var failed = sample
                failed.maintenanceAction = .verifyFailed
                failed.reason = String(describing: error)
                if samples.count < sampleCap { samples.append(failed) }
            }
        }

        let conversationCount = rows.count
        let damagedCount = verifyAndRepair
            ? quarantined + verifyFailed
            : verifyFailed + samples.count
        let ratio = conversationCount > 0 ? Double(damagedCount) / Double(conversationCount) : 0
        let severity: SessionTranscriptIntegritySeverity
        if damagedCount == 0 {
            severity = .normal
        } else if ratio > damagedRatioThreshold {
            severity = .storeAbsentSuspected
        } else {
            severity = .elevated
        }

        return SessionTranscriptIntegrityReport(
            conversationCount: conversationCount,
            autoRepairedCount: autoRepaired,
            quarantinedCount: quarantined,
            verifyFailedCount: verifyFailed,
            severity: severity,
            samples: samples
        )
    }

    private struct ConversationRow: Sendable {
        var conversationID: UUID
        var agentId: String
    }

    private final class InstallCatalogReader {
        private var db: OpaquePointer?

        init(root: URL) throws {
            let catalogURL = SessionPersistenceLayout.catalogURL(root: root)
            guard FileManager.default.fileExists(atPath: catalogURL.path) else { return }
            let rc = sqlite3_open_v2(catalogURL.path, &db, SQLITE_OPEN_READONLY, nil)
            guard rc == SQLITE_OK, db != nil else {
                if let db { sqlite3_close(db) }
                throw SessionPersistenceError.catalogStoreFailed(operation: "transcript_integrity_scan_open", sqliteCode: Int32(rc))
            }
        }

        deinit {
            if let db { sqlite3_close(db) }
        }

        func listConversationRows() throws -> [ConversationRow] {
            guard let db else { return [] }
            let sql = "SELECT id, agent_id FROM conversations;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SessionPersistenceError.catalogStoreFailed(operation: "transcript_integrity_scan_list", sqliteCode: nil)
            }
            var rows: [ConversationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cidText = sqlite3_column_text(stmt, 0),
                      let conversationID = UUID(uuidString: String(cString: cidText))
                else { continue }
                let agentId: String
                if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                    agentId = SessionPersistenceLayout.defaultAgentId
                } else {
                    agentId = String(cString: sqlite3_column_text(stmt, 1))
                }
                rows.append(ConversationRow(conversationID: conversationID, agentId: agentId))
            }
            return rows
        }
    }
}

enum SessionTranscriptIntegrityMaintenance {
    static func logReport(_ report: SessionTranscriptIntegrityReport, phase: String, logger: Logger?) {
        let summary =
            "SAH_SESSION_TRANSCRIPT_INTEGRITY phase=\(phase) conversations=\(report.conversationCount) " +
            "autoRepaired=\(report.autoRepairedCount) quarantined=\(report.quarantinedCount) " +
            "verifyFailed=\(report.verifyFailedCount) severity=\(report.severity.rawValue)"
        let changed = report.autoRepairedCount + report.quarantinedCount + report.verifyFailedCount
        switch report.severity {
        case .normal:
            if changed > 0 {
                logger?.info("\(summary)")
            }
        case .elevated:
            logger?.warning("\(summary) samples=\(report.samples.count)")
        case .storeAbsentSuspected:
            logger?.error("\(summary) transcript store appears absent or incomplete for one or more conversations")
        }
    }
}
