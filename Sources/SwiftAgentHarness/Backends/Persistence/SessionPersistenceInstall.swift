//
//  Wires README ``SessionBackend`` (``LocalHarnessSessionPersistence``) when `SAH_SESSION_STORE_ROOT` is set.
//

import Foundation
import Logging

enum SessionPersistenceInstall {
    private static let catalogBusyRetryAttempts = 10
    private static let installLock = NSLock()

    /// Installs harness persistence on `manager` when a session store root directory is configured.
    ///
    /// **Always** ``LocalHarnessSessionPersistence`` — catalog + JSONL are harness authority when installed.
    ///
    /// **Bootstrap:** runs synchronously while constructing ``ConversationPersistenceStack`` inside ``ConversationPersistenceDomain/makeProduction`` / ``makeForTesting`` — keep this **`throws`** surface stable; optional **`async`** factories belong at composition roots once startup uniformly awaits persistence setup.
    static func applyToConversationManagerIfConfigured(_ manager: ConversationManager, logger: Logger? = nil) throws {
        guard let root = SessionPersistenceConfiguration.sessionStoreRoot else { return }
        installLock.lock()
        defer { installLock.unlock() }

        let local: LocalHarnessSessionPersistence
        var attempt = 1
        while true {
            do {
                local = try LocalHarnessSessionPersistence(
                    root: root,
                    agentId: SessionPersistenceConfiguration.sessionAgentId,
                    logger: logger
                )
                break
            } catch let error as SessionPersistenceError where error == .catalogBusy && attempt < catalogBusyRetryAttempts {
                let delayMs = min(1500, 150 * attempt)
                logger?.warning(
                    "SessionPersistenceInstall catalog busy during LocalHarnessSessionPersistence init. retry=\(attempt)/\(catalogBusyRetryAttempts - 1) delayMs=\(delayMs) root=\(root.path)"
                )
                Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                attempt += 1
            } catch let error as SessionPersistenceError where error == .catalogBusy {
                throw SessionPersistenceError.unsupportedOperation(
                    "catalog_busy_after_retries root=\(root.path) attempts=\(catalogBusyRetryAttempts). " +
                        "Another process is holding SQLite write locks for catalog.sqlite(.wal/.shm); close external DB inspectors and stale server/test processes, then restart."
                )
            } catch {
                throw error
            }
        }

        try SessionPersistenceRecoveryIndexWriter.writeActiveAuthProfileHintIfNeeded(root: root)

        manager.setHarnessSessionPersistenceOverride(local)
        logger?.info("SAH_SESSION_STORE_ROOT: LocalHarnessSessionPersistence at \(root.path)")
        if SessionPersistenceConfiguration.blobSweepOnStartup {
            let swept = try local.sweepExpiredBlobs()
            if swept > 0 {
                logger?.info("SAH_SESSION_BLOB_SWEEP_ON_STARTUP: swept=\(swept)")
            }
        }
        if SessionPersistenceConfiguration.blobReclaimOnStartup {
            let report = try SessionBlobReferenceScanner.integrityReport(
                root: root,
                graceSeconds: SessionPersistenceConfiguration.blobReclaimGraceSeconds,
                reclaimUnreferenced: true
            )
            logBlobIntegrityReport(report, logger: logger)
        }
    }

    private static func logBlobIntegrityReport(_ report: SessionBlobIntegrityReport, logger: Logger?) {
        let summary =
            "SAH_SESSION_BLOB_INTEGRITY referenced=\(report.referencedCount) " +
            "dangling=\(report.danglingCount) ratio=\(String(format: "%.3f", report.danglingRatio)) " +
            "trashed=\(report.trashedUnreferencedCount) hardDeleted=\(report.hardDeletedTrashCount) " +
            "severity=\(report.severity.rawValue)"
        let reclaimed = report.trashedUnreferencedCount + report.hardDeletedTrashCount
        switch report.severity {
        case .normal:
            if reclaimed > 0 {
                logger?.info("\(summary)")
            }
        case .elevated:
            logger?.warning("\(summary) samples=\(report.danglingSamples.count)")
        case .storeAbsentSuspected:
            logger?.error(
                "\(summary) durable media store appears absent or incomplete — verify SAH_SESSION_STORE_ROOT mount"
            )
        }
    }
}
