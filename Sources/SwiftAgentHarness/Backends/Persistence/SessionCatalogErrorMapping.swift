//
//  Maps internal SQLite catalog errors to ``SessionPersistenceError`` at the v2 boundary.
//

import Foundation
import SQLite3

enum SessionCatalogErrorMapping {
    static func persistenceError(from error: SQLiteSessionCatalogError) -> SessionPersistenceError {
        switch error {
        case .schemaNewerThanBinary(let found, let supported):
            return .schemaUpgradeRequired(foundCatalogVersion: found, supportedCatalogVersion: supported)
        case .migrationPreflightFailed(let reasonKey):
            return .catalogIntegrityFailed(reason: reasonKey)
        case .openFailed(let code):
            return .catalogStoreFailed(operation: "catalog_open", sqliteCode: code)
        case .execFailed(let code, let operation):
            if isBusy(code) { return .catalogBusy }
            return .catalogStoreFailed(operation: operation, sqliteCode: code)
        case .prepareFailed(let code, let operation):
            if isBusy(code) { return .catalogBusy }
            return .catalogStoreFailed(operation: operation, sqliteCode: code)
        case .stepFailed(let code, let operation):
            if isBusy(code) { return .catalogBusy }
            return .catalogStoreFailed(operation: operation, sqliteCode: code)
        case .uniqueConstraintViolated(let operation, let code, let message):
            return .duplicateCatalogTitle(reason: "catalog_unique_constraint:\(operation):sqlite=\(code):\(message)")
        }
    }

    static func persistenceError(from error: SessionSQLiteStoreError) -> SessionPersistenceError {
        switch error {
        case .openFailed(let c):
            return .catalogStoreFailed(operation: "dedupe_open", sqliteCode: c)
        case .execFailed(let c):
            if isBusy(c) { return .catalogBusy }
            return .catalogStoreFailed(operation: "dedupe_exec", sqliteCode: c)
        case .prepareFailed(let c):
            if isBusy(c) { return .catalogBusy }
            return .catalogStoreFailed(operation: "dedupe_prepare", sqliteCode: c)
        case .stepFailed(let c):
            if isBusy(c) { return .catalogBusy }
            return .catalogStoreFailed(operation: "dedupe_step", sqliteCode: c)
        }
    }

    static func persistenceError(fromJSONLReader error: SessionJSONLTranscriptReaderError) -> SessionPersistenceError {
        switch error {
        case .transcriptFileMissing:
            return .catalogStoreFailed(operation: "jsonl_read_missing", sqliteCode: nil)
        case .invalidUTF8:
            return .transcriptPayloadInvalid(reason: "jsonl_invalid_utf8")
        case .invalidHeader:
            return .transcriptPayloadInvalid(reason: "jsonl_invalid_header")
        }
    }

    static func persistenceError(fromJSONLWriter error: SessionJSONLTranscriptWriterError) -> SessionPersistenceError {
        switch error {
        case .encodingFailed:
            return .transcriptPayloadInvalid(reason: "jsonl_encode")
        case .transcriptFileOpenFailed:
            return .catalogStoreFailed(operation: "jsonl_append_open", sqliteCode: nil)
        case .transcriptFileMissing:
            return .catalogStoreFailed(operation: "jsonl_truncate_missing", sqliteCode: nil)
        case .transcriptTruncateInvalid:
            return .catalogStoreFailed(operation: "jsonl_truncate_invalid", sqliteCode: nil)
        }
    }

    static func persistenceError(from error: Error) -> SessionPersistenceError {
        if let s = error as? SQLiteSessionCatalogError {
            return persistenceError(from: s)
        }
        if let s = error as? SessionSQLiteStoreError {
            return persistenceError(from: s)
        }
        if let e = error as? SessionJSONLTranscriptReaderError {
            return persistenceError(fromJSONLReader: e)
        }
        if let e = error as? SessionJSONLTranscriptWriterError {
            return persistenceError(fromJSONLWriter: e)
        }
        return .catalogStoreFailed(
            operation: "unexpected_error:\(String(reflecting: type(of: error))):\(error.localizedDescription)",
            sqliteCode: nil
        )
    }

    private static func isBusy(_ code: Int32) -> Bool {
        code == SQLITE_BUSY || code == SQLITE_LOCKED
    }
}
