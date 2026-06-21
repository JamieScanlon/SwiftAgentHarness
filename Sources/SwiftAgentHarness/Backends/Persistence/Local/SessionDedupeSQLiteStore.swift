//
//  TTL idempotency cache (`cache/dedupe.sqlite`) — separate from catalog per harness README.
//

import Foundation
import SQLite3

/// Use of @unchecked Sendable is valid here
final class SessionDedupeSQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rc = sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, db != nil else {
            throw SessionSQLiteStoreError.openFailed(sqliteCode: Int32(rc))
        }
        try exec("PRAGMA busy_timeout=\(SessionPersistenceConfiguration.sqliteBusyTimeoutMilliseconds);")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS dedupe (
              key TEXT PRIMARY KEY,
              expires_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_dedupe_expires ON dedupe(expires_at);
            """
        )
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        guard let db else { return }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { sqlite3_free(err) }
            throw SessionSQLiteStoreError.execFailed(sqliteCode: rc)
        }
    }

    /// Returns `true` when an unexpired row exists for `key`.
    func dedupePeek(key: String, now: Date = Date()) throws -> Bool {
        guard let db else { return false }
        try purgeExpired(now: now)
        let sql = "SELECT 1 FROM dedupe WHERE key = ? AND expires_at >= ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SessionSQLiteStoreError.prepareFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLite3Transient.destructor)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            throw SessionSQLiteStoreError.stepFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
        return rc == SQLITE_ROW
    }

    /// Returns `true` if this is the first sighting (caller should proceed); `false` if duplicate.
    func dedupeCheckAndSet(key: String, ttlSeconds: Int, now: Date = Date()) throws -> Bool {
        guard let db else { return true }
        try purgeExpired(now: now)
        let sql = "INSERT OR IGNORE INTO dedupe (key, expires_at) VALUES (?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SessionSQLiteStoreError.prepareFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
        let expires = now.addingTimeInterval(TimeInterval(ttlSeconds)).timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, key, -1, SQLite3Transient.destructor)
        sqlite3_bind_double(stmt, 2, expires)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SessionSQLiteStoreError.stepFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
        return sqlite3_changes(db) > 0
    }

    private func purgeExpired(now: Date) throws {
        guard let db else { return }
        let sql = "DELETE FROM dedupe WHERE expires_at < ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SessionSQLiteStoreError.prepareFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SessionSQLiteStoreError.stepFailed(sqliteCode: sqlite3_extended_errcode(db))
        }
    }
}
