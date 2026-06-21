//
//  WAL catalog for LocalHarnessSessionPersistence (subset of harness spec; FTS5 + triggers).
//

import Foundation
import SQLite3

enum SQLiteSessionCatalogError: Error, Sendable {
    case openFailed(sqliteCode: Int32)
    case execFailed(sqliteCode: Int32, operation: String)
    case prepareFailed(sqliteCode: Int32, operation: String)
    case stepFailed(sqliteCode: Int32, operation: String)
    case uniqueConstraintViolated(operation: String, sqliteCode: Int32, message: String)
    /// Stored catalog schema version exceeds this binary (``SQLiteSessionCatalog/kSupportedCatalogSchemaVersion``).
    case schemaNewerThanBinary(found: Int, supported: Int)
    /// Non-SQLite catalog guard (e.g. duplicate titles before v6); maps to ``SessionPersistenceError/catalogIntegrityFailed``.
    case migrationPreflightFailed(reasonKey: String)
}

/// Single-file SQLite catalog (`catalog.sqlite`). Not `Sendable`; owned by ``LocalHarnessSessionPersistence`` on one isolation domain.
final class SQLiteSessionCatalog {
    /// Highest schema version this build can open (migrations target this); opening a newer DB yields ``SQLiteSessionCatalogError/schemaNewerThanBinary``.
    static let kSupportedCatalogSchemaVersion = 18

    private var db: OpaquePointer?
    private let agentId: String

    private func sqliteErrorMessage() -> String {
        guard let db else { return "no_db_handle" }
        guard let cString = sqlite3_errmsg(db) else { return "unknown_sqlite_error" }
        return String(cString: cString)
    }

    init(fileURL: URL, agentId: String = SessionPersistenceLayout.defaultAgentId) throws {
        self.agentId = agentId
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = fileURL.path
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, db != nil else {
            let code = Int32(rc)
            if let db { sqlite3_close(db) }
            throw SQLiteSessionCatalogError.openFailed(sqliteCode: code)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=\(SessionPersistenceConfiguration.sqliteBusyTimeoutMilliseconds);")
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// P4: application-level busy backoff beyond `PRAGMA busy_timeout`.
    private static let maxBusyRetryLoops = 48

    private func sleepForBusyRetry(attempt: Int) {
        let exp = min(7, max(0, attempt - 1))
        let baseMs = min(4 * (1 << exp), 200)
        let jitter = Int.random(in: 0...12)
        let totalMs = baseMs + jitter
        Thread.sleep(forTimeInterval: Double(totalMs) / 1000.0)
    }

    private func sqliteExtendedCode() -> Int32 {
        guard let db else { return 0 }
        return sqlite3_extended_errcode(db)
    }

    private func stepOnce(_ stmt: OpaquePointer?) throws -> Int32 {
        guard db != nil else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "catalog_closed")
        }
        var busyAttempt = 0
        while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW, SQLITE_DONE:
                return rc
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyAttempt += 1
                guard busyAttempt < Self.maxBusyRetryLoops else {
                    throw SQLiteSessionCatalogError.stepFailed(
                        sqliteCode: sqliteExtendedCode(),
                        operation: "sql_step_busy_exhausted"
                    )
                }
                sleepForBusyRetry(attempt: busyAttempt)
            default:
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
        }
    }

    /// Expects `SQLITE_DONE`; maps `SQLITE_CONSTRAINT` to ``uniqueConstraintViolated`` (partial unique title index, etc.).
    private func stepUntilDoneHandlingUnique(_ stmt: OpaquePointer?, operation: String) throws {
        guard db != nil else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "catalog_closed")
        }
        var busyAttempt = 0
        while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_DONE:
                return
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyAttempt += 1
                guard busyAttempt < Self.maxBusyRetryLoops else {
                    throw SQLiteSessionCatalogError.stepFailed(
                        sqliteCode: sqliteExtendedCode(),
                        operation: "sql_step_busy_exhausted"
                    )
                }
                sleepForBusyRetry(attempt: busyAttempt)
            case SQLITE_CONSTRAINT:
                throw SQLiteSessionCatalogError.uniqueConstraintViolated(
                    operation: operation,
                    sqliteCode: sqliteExtendedCode(),
                    message: sqliteErrorMessage()
                )
            default:
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
        }
    }

    private func forEachRow(_ stmt: OpaquePointer?, _ body: (OpaquePointer?) throws -> Void) throws {
        guard db != nil else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "catalog_closed")
        }
        while true {
            let rc = try stepOnce(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
            try body(stmt)
        }
    }

    func exec(_ sql: String) throws {
        guard let db else { return }
        var busyAttempt = 0
        while true {
            var err: UnsafeMutablePointer<Int8>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                if let err { sqlite3_free(err) }
                busyAttempt += 1
                guard busyAttempt < Self.maxBusyRetryLoops else {
                    throw SQLiteSessionCatalogError.execFailed(
                        sqliteCode: sqliteExtendedCode(),
                        operation: "sql_exec_busy_exhausted"
                    )
                }
                sleepForBusyRetry(attempt: busyAttempt)
                continue
            }
            if rc != SQLITE_OK {
                if let err { sqlite3_free(err) }
                throw SQLiteSessionCatalogError.execFailed(sqliteCode: rc, operation: "sql_exec")
            }
            return
        }
    }

    private func migrate() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS schema_version (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              version INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO schema_version (id, version) VALUES (1, 1);

            CREATE TABLE IF NOT EXISTS conversations (
              id TEXT PRIMARY KEY,
              topic TEXT,
              description TEXT,
              message_count INTEGER NOT NULL DEFAULT 0,
              updated_at REAL NOT NULL,
              created_at REAL NOT NULL,
              model_name TEXT NOT NULL,
              interaction_mode TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
              rowid INTEGER PRIMARY KEY AUTOINCREMENT,
              id TEXT NOT NULL,
              conversation_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              role TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              timestamp REAL NOT NULL,
              UNIQUE(conversation_id, sequence),
              FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_messages_conversation_sequence ON messages(conversation_id, sequence);
            """
        )

        try exec(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
              payload_json,
              conversation_id UNINDEXED,
              content='messages',
              content_rowid='rowid'
            );
            """
        )

        try exec(
            """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, payload_json, conversation_id) VALUES (new.rowid, new.payload_json, new.conversation_id);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, payload_json, conversation_id) VALUES('delete', old.rowid, old.payload_json, old.conversation_id);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, payload_json, conversation_id) VALUES('delete', old.rowid, old.payload_json, old.conversation_id);
              INSERT INTO messages_fts(rowid, payload_json, conversation_id) VALUES (new.rowid, new.payload_json, new.conversation_id);
            END;
            """
        )

        try migrateSchemaV2ParentEntryColumn()
        try migrateSchemaV3ConversationHarnessColumns()
        try migrateSchemaV4ConversationAgentId()
        try migrateSchemaV5HarnessTasks()
        try migrateSchemaV6UniqueAgentTitle()
        try migrateSchemaV7StateMeta()
        try migrateSchemaV8TasksRegistry()
        try migrateSchemaV9MessageContentFTS()
        try migrateSchemaV10ModeProfilePointer()
        try migrateSchemaV11MessageRichColumns()
        try migrateSchemaV12AttachmentRefsColumn()
        try migrateSchemaV13HeadEntryIdColumn()
        try migrateSchemaV14ResourceColumns()
        try migrateSchemaV15TranscriptIntegrityColumn()
        try migrateSchemaV16DropAgentPhaseColumn()
        try migrateSchemaV17ConversationKindColumns()
        try migrateSchemaV18RenameControlPlaneRevisionColumn()
        let v = try currentSchemaVersion()
        if v > Self.kSupportedCatalogSchemaVersion {
            throw SQLiteSessionCatalogError.schemaNewerThanBinary(found: v, supported: Self.kSupportedCatalogSchemaVersion)
        }
    }

    private func messagesHasColumn(name: String) throws -> Bool {
        guard let db else { return false }
        let sql = "PRAGMA table_info(messages);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        var found = false
        try forEachRow(stmt) { s in
            let colName = String(cString: sqlite3_column_text(s, 1))
            if colName == name { found = true }
        }
        return found
    }

    private func conversationsHasColumn(name: String) throws -> Bool {
        guard let db else { return false }
        let sql = "PRAGMA table_info(conversations);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        var found = false
        try forEachRow(stmt) { s in
            let colName = String(cString: sqlite3_column_text(s, 1))
            if colName == name { found = true }
        }
        return found
    }

    /// Idempotent: add `parent_entry_id` for harness tree linkage (P0).
    private func migrateSchemaV2ParentEntryColumn() throws {
        if try messagesHasColumn(name: "parent_entry_id") {
            return
        }
        try exec("ALTER TABLE messages ADD COLUMN parent_entry_id TEXT;")
        try exec("UPDATE schema_version SET version = 2 WHERE id = 1;")
    }

    /// P1 harness catalog columns on `conversations`.
    private func migrateSchemaV3ConversationHarnessColumns() throws {
        if try conversationsHasColumn(name: "source") { return }

        try exec("ALTER TABLE conversations ADD COLUMN source TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN trust_class TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN parent_conversation_id TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN fork_anchor_entry_id TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN user_id TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN lifecycle_state TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN title TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN cwd TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN ended_at REAL;")
        try exec("ALTER TABLE conversations ADD COLUMN end_reason TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN tool_call_count INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN total_prompt_tokens INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN total_completion_tokens INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN total_cost_minor_units INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN model_config_json TEXT;")
        try exec("ALTER TABLE conversations ADD COLUMN reasoning_tokens INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN cache_tokens INTEGER;")
        try exec("ALTER TABLE conversations ADD COLUMN title_version INTEGER NOT NULL DEFAULT 0;")
        try exec("ALTER TABLE conversations ADD COLUMN first_user_prompt TEXT;")

        try exec("CREATE INDEX IF NOT EXISTS idx_conversations_parent ON conversations(parent_conversation_id);")
        try exec("UPDATE schema_version SET version = 3 WHERE id = 1;")
    }

    /// P3b agent scoping on `conversations` (transcript path owner per store root).
    private func migrateSchemaV4ConversationAgentId() throws {
        if try conversationsHasColumn(name: "agent_id") {
            return
        }
        try exec("ALTER TABLE conversations ADD COLUMN agent_id TEXT NOT NULL DEFAULT 'default';")
        try exec("CREATE INDEX IF NOT EXISTS idx_conversations_agent ON conversations(agent_id);")
        try exec("UPDATE schema_version SET version = 4 WHERE id = 1;")
    }

    /// P3c durable task/cron enqueue index (JSONL audit log lives under `cron/runs/`).
    private func migrateSchemaV5HarnessTasks() throws {
        guard try currentSchemaVersion() < 5 else { return }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS harness_tasks (
              rowid INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL,
              run_id TEXT NOT NULL,
              idempotency_key TEXT,
              payload BLOB NOT NULL,
              status TEXT NOT NULL,
              created_at REAL NOT NULL,
              delivered_at REAL,
              UNIQUE(run_id)
            );
            """
        )
        try exec(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_harness_tasks_idempotency
            ON harness_tasks(idempotency_key)
            WHERE idempotency_key IS NOT NULL;
            """
        )
        try exec(
            """
            CREATE INDEX IF NOT EXISTS idx_harness_tasks_job_status_created
            ON harness_tasks(job_id, status, created_at);
            """
        )
        try exec("UPDATE schema_version SET version = 5 WHERE id = 1;")
    }

    /// Gap 3: partial unique index on `(agent_id, title)` for non-null titles (harness `sessions(title)` analog).
    private func migrateSchemaV6UniqueAgentTitle() throws {
        guard try currentSchemaVersion() < 6 else { return }
        try assertNoDuplicateNonNullAgentTitles()
        try exec(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_agent_title_unique
            ON conversations(agent_id, title) WHERE title IS NOT NULL;
            """
        )
        try exec("UPDATE schema_version SET version = 6 WHERE id = 1;")
    }

    private func migrateSchemaV7StateMeta() throws {
        guard try currentSchemaVersion() < 7 else { return }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS state_meta (
              key TEXT PRIMARY KEY,
              value TEXT
            );
            """
        )
        try exec("UPDATE schema_version SET version = 7 WHERE id = 1;")
    }

    /// Gap 7 — README catalog `tasks` (scheduled definitions); payload is opaque JSON bytes from callers.
    private func migrateSchemaV8TasksRegistry() throws {
        guard try currentSchemaVersion() < 8 else { return }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS tasks (
              task_id TEXT PRIMARY KEY,
              agent_id TEXT,
              payload BLOB NOT NULL,
              updated_at REAL NOT NULL
            );
            """
        )
        try exec("CREATE INDEX IF NOT EXISTS idx_tasks_agent_id ON tasks(agent_id);")
        try exec("UPDATE schema_version SET version = 8 WHERE id = 1;")
    }

    /// FTS: README `messages.content` + FTS5 over body text.
    private func migrateSchemaV9MessageContentFTS() throws {
        guard try currentSchemaVersion() < 9 else { return }
        if try !messagesHasColumn(name: "content") {
            try exec("ALTER TABLE messages ADD COLUMN content TEXT NOT NULL DEFAULT '';")
        }
        try backfillMessagesContentForFTS()
        try exec("DROP TRIGGER IF EXISTS messages_ai;")
        try exec("DROP TRIGGER IF EXISTS messages_ad;")
        try exec("DROP TRIGGER IF EXISTS messages_au;")
        try exec("DROP TABLE IF EXISTS messages_fts;")
        try exec(
            """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
              content,
              conversation_id UNINDEXED,
              content='messages',
              content_rowid='rowid'
            );
            """
        )
        try exec(
            """
            CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, content, conversation_id) VALUES (new.rowid, new.content, new.conversation_id);
            END;
            CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, content, conversation_id) VALUES('delete', old.rowid, old.content, old.conversation_id);
            END;
            CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, content, conversation_id) VALUES('delete', old.rowid, old.content, old.conversation_id);
              INSERT INTO messages_fts(rowid, content, conversation_id) VALUES (new.rowid, new.content, new.conversation_id);
            END;
            """
        )
        try exec("INSERT INTO messages_fts(messages_fts) VALUES('rebuild');")
        try exec("UPDATE schema_version SET version = 9 WHERE id = 1;")
    }

    /// Denormalized harness README message columns (tool calls, response format, finish reason).
    private func migrateSchemaV11MessageRichColumns() throws {
        guard try currentSchemaVersion() < 11 else { return }
        if try !messagesHasColumn(name: "tool_call_id") {
            try exec("ALTER TABLE messages ADD COLUMN tool_call_id TEXT;")
        }
        if try !messagesHasColumn(name: "tool_calls_json") {
            try exec("ALTER TABLE messages ADD COLUMN tool_calls_json TEXT;")
        }
        if try !messagesHasColumn(name: "response_format") {
            try exec("ALTER TABLE messages ADD COLUMN response_format TEXT;")
        }
        if try !messagesHasColumn(name: "finish_reason") {
            try exec("ALTER TABLE messages ADD COLUMN finish_reason TEXT;")
        }
        try backfillMessageRichColumnsFromPayload()
        try exec("UPDATE schema_version SET version = 11 WHERE id = 1;")
    }

    private func migrateSchemaV12AttachmentRefsColumn() throws {
        guard try currentSchemaVersion() < 12 else { return }
        if try !messagesHasColumn(name: "attachment_refs_json") {
            try exec("ALTER TABLE messages ADD COLUMN attachment_refs_json TEXT;")
        }
        try backfillMessageAttachmentRefsFromPayload()
        try exec("UPDATE schema_version SET version = 12 WHERE id = 1;")
    }

    private func migrateSchemaV13HeadEntryIdColumn() throws {
        guard try currentSchemaVersion() < 13 else { return }
        if try !conversationsHasColumn(name: "head_entry_id") {
            try exec("ALTER TABLE conversations ADD COLUMN head_entry_id TEXT;")
        }
        try exec(
            """
            UPDATE conversations SET head_entry_id = (
              SELECT m.id FROM messages m
              WHERE m.conversation_id = conversations.id
                AND m.role IN ('message', 'system')
              ORDER BY m.sequence DESC LIMIT 1
            )
            WHERE head_entry_id IS NULL
              AND EXISTS (
                SELECT 1 FROM messages m
                WHERE m.conversation_id = conversations.id
                  AND m.role IN ('message', 'system')
              );
            """
        )
        try exec("UPDATE schema_version SET version = 13 WHERE id = 1;")
    }

    private func migrateSchemaV14ResourceColumns() throws {
        guard try currentSchemaVersion() < 14 else { return }
        if try !conversationsHasColumn(name: "resource_json") {
            try exec("ALTER TABLE conversations ADD COLUMN resource_json TEXT;")
        }
        if try !conversationsHasColumn(name: "current_run_id") {
            try exec("ALTER TABLE conversations ADD COLUMN current_run_id TEXT;")
        }
        if try !conversationsHasColumn(name: "last_active_at") {
            try exec("ALTER TABLE conversations ADD COLUMN last_active_at REAL;")
        }
        if try !conversationsHasColumn(name: "resource_run_status") {
            try exec("ALTER TABLE conversations ADD COLUMN resource_run_status TEXT;")
        }
        if try !conversationsHasColumn(name: "metadata_json") {
            try exec("ALTER TABLE conversations ADD COLUMN metadata_json TEXT;")
        }
        if try !conversationsHasColumn(name: "system_prompt") {
            try exec("ALTER TABLE conversations ADD COLUMN system_prompt TEXT;")
        }
        try exec("UPDATE schema_version SET version = 14 WHERE id = 1;")
    }

    private func migrateSchemaV15TranscriptIntegrityColumn() throws {
        guard try currentSchemaVersion() < 15 else { return }
        if try !conversationsHasColumn(name: "transcript_integrity") {
            try exec("ALTER TABLE conversations ADD COLUMN transcript_integrity TEXT;")
        }
        try exec("UPDATE schema_version SET version = 15 WHERE id = 1;")
    }

    /// Drops legacy `agent_phase` (superseded by `interaction_mode`); pre-v16 catalogs fail inserts without this.
    private func migrateSchemaV16DropAgentPhaseColumn() throws {
        guard try currentSchemaVersion() < 16 else { return }
        if try conversationsHasColumn(name: "agent_phase") {
            try exec("ALTER TABLE conversations DROP COLUMN agent_phase;")
        }
        try exec("UPDATE schema_version SET version = 16 WHERE id = 1;")
    }

    private func migrateSchemaV17ConversationKindColumns() throws {
        guard try currentSchemaVersion() < 17 else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            if try !conversationsHasColumn(name: "conversation_lineage_kind") {
                try exec("ALTER TABLE conversations ADD COLUMN conversation_lineage_kind TEXT NOT NULL DEFAULT 'root';")
            }
            if try !conversationsHasColumn(name: "conversation_origin") {
                try exec("ALTER TABLE conversations ADD COLUMN conversation_origin TEXT NOT NULL DEFAULT 'user';")
            }
            try exec("""
            CREATE INDEX IF NOT EXISTS idx_conversations_agent_kind_origin
            ON conversations(agent_id, conversation_lineage_kind, conversation_origin);
            """)
            try backfillConversationKindColumns()
            try exec("UPDATE schema_version SET version = 17 WHERE id = 1;")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Renames legacy `title_version` to `control_plane_revision` (optimistic concurrency token for control-plane mutations).
    private func migrateSchemaV18RenameControlPlaneRevisionColumn() throws {
        guard try currentSchemaVersion() < 18 else { return }
        if try conversationsHasColumn(name: "title_version") {
            try exec("ALTER TABLE conversations RENAME COLUMN title_version TO control_plane_revision;")
        }
        try exec("UPDATE schema_version SET version = 18 WHERE id = 1;")
    }

    private func backfillConversationKindColumns() throws {
        guard let db else { return }
        let sql = """
        SELECT id, interaction_mode, mode_profile_id, topic, parent_conversation_id, fork_anchor_entry_id, metadata_json
        FROM conversations;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        let updSql = """
        UPDATE conversations SET conversation_lineage_kind = ?, conversation_origin = ?
        WHERE id = ?;
        """
        var updStmt: OpaquePointer?
        defer { sqlite3_finalize(updStmt) }
        guard sqlite3_prepare_v2(db, updSql, -1, &updStmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        try forEachRow(stmt) { s in
            let id = String(cString: sqlite3_column_text(s, 0))
            let mode = String(cString: sqlite3_column_text(s, 1))
            let modeProfileID = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 2))
            let topic = sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 3))
            let parentStr = sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 4))
            let forkStr = sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 5))
            let metadataJSON = sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, 6))
            let parentID = parentStr.flatMap(UUID.init(uuidString:))
            let inferred = ConversationLineageInference.infer(
                metadataJSON: metadataJSON,
                interactionModeRaw: mode,
                modeProfileID: modeProfileID,
                topic: topic,
                parentConversationID: parentID,
                forkAnchorEntryID: forkStr
            )
            sqlite3_reset(updStmt)
            sqlite3_clear_bindings(updStmt)
            sqlite3_bind_text(updStmt, 1, inferred.lineage.rawValue, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(updStmt, 2, inferred.origin.rawValue, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(updStmt, 3, id, -1, SQLite3Transient.destructor)
            _ = try stepOnce(updStmt)
        }
    }

    private func backfillMessageAttachmentRefsFromPayload() throws {
        guard let db else { return }
        let sql = "SELECT rowid, payload_json FROM messages;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        let updSql = """
        UPDATE messages SET attachment_refs_json = ?, content = ?
        WHERE rowid = ?;
        """
        var updStmt: OpaquePointer?
        defer { sqlite3_finalize(updStmt) }
        guard sqlite3_prepare_v2(db, updSql, -1, &updStmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        try forEachRow(stmt) { s in
            let rowid = sqlite3_column_int64(s, 0)
            let payload = String(cString: sqlite3_column_text(s, 1))
            let entry = Self.migrationTranscriptEntry(role: SessionTranscriptEntryType.message.rawValue, payloadJSON: payload)
            let columns = MessageTranscriptPayloadCodec.catalogColumns(for: payload)
            let content = SessionMessageContentExtractor.ftsIndexedContent(for: entry)
            sqlite3_reset(updStmt)
            sqlite3_clear_bindings(updStmt)
            bindOptionalText(updStmt, 1, columns.attachmentRefsJSON)
            sqlite3_bind_text(updStmt, 2, content, -1, SQLite3Transient.destructor)
            sqlite3_bind_int64(updStmt, 3, rowid)
            _ = try stepOnce(updStmt)
        }
    }

    private func backfillMessageRichColumnsFromPayload() throws {
        guard let db else { return }
        let sql = "SELECT rowid, payload_json FROM messages;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        let updSql = """
        UPDATE messages SET tool_call_id = ?, tool_calls_json = ?, response_format = ?, finish_reason = ?, content = ?
        WHERE rowid = ?;
        """
        var updStmt: OpaquePointer?
        defer { sqlite3_finalize(updStmt) }
        guard sqlite3_prepare_v2(db, updSql, -1, &updStmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        try forEachRow(stmt) { s in
            let rowid = sqlite3_column_int64(s, 0)
            let payload = String(cString: sqlite3_column_text(s, 1))
            let entry = Self.migrationTranscriptEntry(role: SessionTranscriptEntryType.message.rawValue, payloadJSON: payload)
            let columns = MessageTranscriptPayloadCodec.catalogColumns(for: payload)
            let content = SessionMessageContentExtractor.ftsIndexedContent(for: entry)
            sqlite3_reset(updStmt)
            sqlite3_clear_bindings(updStmt)
            bindOptionalText(updStmt, 1, columns.toolCallId)
            bindOptionalText(updStmt, 2, columns.toolCallsJSON)
            bindOptionalText(updStmt, 3, columns.responseFormat)
            bindOptionalText(updStmt, 4, columns.finishReason)
            sqlite3_bind_text(updStmt, 5, content, -1, SQLite3Transient.destructor)
            sqlite3_bind_int64(updStmt, 6, rowid)
            _ = try stepOnce(updStmt)
        }
    }

    /// Persisted `ModeRegistry` pointer independent of coarse `interaction_mode`.
    private func migrateSchemaV10ModeProfilePointer() throws {
        guard try currentSchemaVersion() < 10 else { return }
        if try !conversationsHasColumn(name: "mode_profile_id") {
            try exec("ALTER TABLE conversations ADD COLUMN mode_profile_id TEXT;")
        }
        try exec("UPDATE schema_version SET version = 10 WHERE id = 1;")
    }

    private func backfillMessagesContentForFTS() throws {
        guard let db else { return }
        let sql = "SELECT rowid, role, payload_json FROM messages;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        let updSql = "UPDATE messages SET content = ? WHERE rowid = ?;"
        var updStmt: OpaquePointer?
        defer { sqlite3_finalize(updStmt) }
        guard sqlite3_prepare_v2(db, updSql, -1, &updStmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        try forEachRow(stmt) { s in
            let rowid = sqlite3_column_int64(s, 0)
            let role = String(cString: sqlite3_column_text(s, 1))
            let payload = String(cString: sqlite3_column_text(s, 2))
            let entry = Self.migrationTranscriptEntry(role: role, payloadJSON: payload)
            let content = SessionMessageContentExtractor.ftsIndexedContent(for: entry)
            sqlite3_reset(updStmt)
            sqlite3_clear_bindings(updStmt)
            sqlite3_bind_text(updStmt, 1, content, -1, SQLite3Transient.destructor)
            sqlite3_bind_int64(updStmt, 2, rowid)
            _ = try stepOnce(updStmt)
        }
    }

    private static func migrationTranscriptEntry(role: String, payloadJSON: String) -> SessionTranscriptEntry {
        if let parsed = SessionTranscriptEntryType(rawValue: role) {
            return SessionTranscriptEntry(
                sequence: 0,
                entryId: .generate(),
                parentEntryId: nil,
                type: parsed,
                harnessTypeRaw: nil,
                timestamp: Date(),
                payloadJSON: payloadJSON
            )
        }
        return SessionTranscriptEntry(
            sequence: 0,
            entryId: .generate(),
            parentEntryId: nil,
            type: .custom,
            harnessTypeRaw: role,
            timestamp: Date(),
            payloadJSON: payloadJSON
        )
    }

    private func assertNoDuplicateNonNullAgentTitles() throws {
        guard let db else { return }
        let sql = """
        SELECT agent_id, title FROM conversations
        WHERE title IS NOT NULL
        GROUP BY agent_id, title
        HAVING COUNT(*) > 1
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        let step = try stepOnce(stmt)
        if step == SQLITE_ROW {
            throw SQLiteSessionCatalogError.migrationPreflightFailed(reasonKey: "duplicate_non_null_titles_before_schema_v6")
        }
    }

    private func currentSchemaVersion() throws -> Int {
        guard let db else { return 1 }
        let sql = "SELECT version FROM schema_version WHERE id = 1 LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        guard try stepOnce(stmt) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Introspection for `sessions.json` recovery snapshot only.
    func exposedSchemaVersionForRecoveryIndex() throws -> Int {
        try currentSchemaVersion()
    }

    func insertConversation(_ record: SessionCatalogRecord) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO conversations (
          id, topic, description, message_count, updated_at, created_at, model_name, interaction_mode, mode_profile_id,
          source, trust_class, parent_conversation_id, fork_anchor_entry_id, head_entry_id, resource_json, current_run_id,
          last_active_at, resource_run_status, metadata_json, system_prompt, user_id, lifecycle_state, title, cwd,
          ended_at, end_reason, tool_call_count, total_prompt_tokens, total_completion_tokens, total_cost_minor_units,
          model_config_json, reasoning_tokens, cache_tokens, control_plane_revision, first_user_prompt, agent_id, transcript_integrity,
          conversation_lineage_kind, conversation_origin
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, SQLite3Transient.destructor)
        bindOptionalText(stmt, 2, record.topic)
        bindOptionalText(stmt, 3, record.description)
        sqlite3_bind_int(stmt, 4, Int32(record.messageCount))
        sqlite3_bind_double(stmt, 5, record.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 7, record.modelName, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 8, record.interactionModeRaw, -1, SQLite3Transient.destructor)
        var i: Int32 = 9
        bindOptionalText(stmt, i, record.modeProfileID)
        i += 1
        bindOptionalText(stmt, i, record.source)
        i += 1
        bindOptionalText(stmt, i, record.trustClass)
        i += 1
        bindOptionalText(stmt, i, record.parentConversationID?.uuidString)
        i += 1
        bindOptionalText(stmt, i, record.forkAnchorEntryID?.rawValue)
        i += 1
        bindOptionalText(stmt, i, record.headEntryId?.rawValue)
        i += 1
        bindOptionalText(stmt, i, record.resourceJSON)
        i += 1
        bindOptionalText(stmt, i, record.currentRunID?.uuidString)
        i += 1
        if let lastActive = record.lastActiveAt {
            sqlite3_bind_double(stmt, i, lastActive.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, i)
        }
        i += 1
        bindOptionalText(stmt, i, record.resourceRunStatusRaw)
        i += 1
        bindOptionalText(stmt, i, record.metadataJSON)
        i += 1
        bindOptionalText(stmt, i, record.systemPrompt)
        i += 1
        bindOptionalText(stmt, i, record.userID)
        i += 1
        bindOptionalText(stmt, i, record.lifecycleStateRaw)
        i += 1
        bindOptionalText(stmt, i, record.title)
        i += 1
        bindOptionalText(stmt, i, record.cwd)
        i += 1
        if let ended = record.endedAt {
            sqlite3_bind_double(stmt, i, ended.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, i)
        }
        i += 1
        bindOptionalText(stmt, i, record.endReason)
        i += 1
        bindOptionalInt(stmt, i, record.toolCallCount)
        i += 1
        bindOptionalInt(stmt, i, record.totalPromptTokens)
        i += 1
        bindOptionalInt(stmt, i, record.totalCompletionTokens)
        i += 1
        bindOptionalInt(stmt, i, record.totalCostMinorUnits)
        i += 1
        bindOptionalText(stmt, i, record.modelConfigJSON)
        i += 1
        bindOptionalInt(stmt, i, record.reasoningTokens)
        i += 1
        bindOptionalInt(stmt, i, record.cacheTokens)
        i += 1
        sqlite3_bind_int(stmt, i, Int32(record.controlPlaneRevision))
        i += 1
        bindOptionalText(stmt, i, record.firstUserPrompt)
        i += 1
        sqlite3_bind_text(stmt, i, record.agentId, -1, SQLite3Transient.destructor)
        i += 1
        bindOptionalText(stmt, i, Self.encodeTranscriptIntegrityColumn(record.transcriptIntegrity))
        i += 1
        sqlite3_bind_text(stmt, i, record.lineageKind.rawValue, -1, SQLite3Transient.destructor)
        i += 1
        sqlite3_bind_text(stmt, i, record.origin.rawValue, -1, SQLite3Transient.destructor)
        try stepUntilDoneHandlingUnique(stmt, operation: "insert_conversation")
    }

    func insertMessage(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        guard let db else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            try insertMessageRow(db: db, conversationID: conversationID, entry: entry)
            try bumpConversationAfterMessage(db: db, conversationID: conversationID, at: entry.timestamp, entry: entry)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func incrementConversationMessageCount(db: OpaquePointer, conversationID: UUID) throws {
        let sql = "UPDATE conversations SET message_count = message_count + 1 WHERE id = ? AND agent_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    private func insertMessageRow(db: OpaquePointer, conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let contentText = SessionMessageContentExtractor.ftsIndexedContent(for: entry)
        let columns = MessageTranscriptPayloadCodec.catalogColumns(for: entry.payloadJSON)
        let sql = """
        INSERT INTO messages (
          id, conversation_id, sequence, role, payload_json, timestamp, parent_entry_id, content,
          tool_call_id, tool_calls_json, attachment_refs_json, response_format, finish_reason
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, entry.entryId.rawValue, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_int(stmt, 3, Int32(entry.sequence))
        sqlite3_bind_text(stmt, 4, entry.persistedTypeRaw, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 5, entry.payloadJSON, -1, SQLite3Transient.destructor)
        sqlite3_bind_double(stmt, 6, entry.timestamp.timeIntervalSince1970)
        if let parent = entry.parentEntryId {
            sqlite3_bind_text(stmt, 7, parent.rawValue, -1, SQLite3Transient.destructor)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, contentText, -1, SQLite3Transient.destructor)
        bindOptionalText(stmt, 9, columns.toolCallId)
        bindOptionalText(stmt, 10, columns.toolCallsJSON)
        bindOptionalText(stmt, 11, columns.attachmentRefsJSON)
        bindOptionalText(stmt, 12, columns.responseFormat)
        bindOptionalText(stmt, 13, columns.finishReason)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func updateMessageRichPayload(conversationID: UUID, sequence: Int, entry: SessionTranscriptEntry) throws {
        guard let db else { return }
        let contentText = SessionMessageContentExtractor.ftsIndexedContent(for: entry)
        let columns = MessageTranscriptPayloadCodec.catalogColumns(for: entry.payloadJSON)
        let sql = """
        UPDATE messages SET payload_json = ?, content = ?, tool_call_id = ?, tool_calls_json = ?, attachment_refs_json = ?, response_format = ?, finish_reason = ?
        WHERE conversation_id = ? AND sequence = ?;
        """
        try exec("BEGIN IMMEDIATE;")
        do {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
            }
            sqlite3_bind_text(stmt, 1, entry.payloadJSON, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(stmt, 2, contentText, -1, SQLite3Transient.destructor)
            bindOptionalText(stmt, 3, columns.toolCallId)
            bindOptionalText(stmt, 4, columns.toolCallsJSON)
            bindOptionalText(stmt, 5, columns.attachmentRefsJSON)
            bindOptionalText(stmt, 6, columns.responseFormat)
            bindOptionalText(stmt, 7, columns.finishReason)
            sqlite3_bind_text(stmt, 8, conversationID.uuidString, -1, SQLite3Transient.destructor)
            sqlite3_bind_int(stmt, 9, Int32(sequence))
            guard try stepOnce(stmt) == SQLITE_DONE else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Next monotonic sequence for `conversation_id` (1-based).
    func nextSequence(conversationID: UUID) throws -> Int {
        guard let db else { return 1 }
        let sql = "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else {
            return 1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Deletes the tail message row when it matches `sequence` and `entryId` (Gap 5 SwiftData failure after v2 append).
    func deleteTailMessage(
        conversationID: UUID,
        sequence: Int,
        entryId: SessionEntryID,
        rollbackTimestamp: Date,
        shouldDecrementCatalogMessageCount: Bool = true
    ) throws {
        guard let db else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            let guardSQL = """
            SELECT id FROM messages WHERE conversation_id = ? ORDER BY sequence DESC LIMIT 1;
            """
            var gStmt: OpaquePointer?
            defer { sqlite3_finalize(gStmt) }
            guard sqlite3_prepare_v2(db, guardSQL, -1, &gStmt, nil) == SQLITE_OK else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
            }
            sqlite3_bind_text(gStmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
            guard try stepOnce(gStmt) == SQLITE_ROW else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "rollback_no_messages")
            }
            let tailId = String(cString: sqlite3_column_text(gStmt, 0))
            guard SessionEntryID(tailId) == entryId else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "rollback_tail_entry_id_mismatch")
            }
            let maxSeq = try latestSequence(conversationID: conversationID)
            guard maxSeq == sequence else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "rollback_tail_sequence_mismatch")
            }
            let del = "DELETE FROM messages WHERE conversation_id = ? AND sequence = ? AND id = ?;"
            var dStmt: OpaquePointer?
            defer { sqlite3_finalize(dStmt) }
            guard sqlite3_prepare_v2(db, del, -1, &dStmt, nil) == SQLITE_OK else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
            }
            sqlite3_bind_text(dStmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
            sqlite3_bind_int(dStmt, 2, Int32(sequence))
            sqlite3_bind_text(dStmt, 3, tailId, -1, SQLite3Transient.destructor)
            guard try stepOnce(dStmt) == SQLITE_DONE else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
            guard sqlite3_changes(db) == 1 else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: 0, operation: "rollback_delete_row_count")
            }
            let catalogTailDecrementSQL = """
            UPDATE conversations
            SET message_count = CASE WHEN ? != 0 AND message_count > 0 THEN message_count - 1 ELSE message_count END,
                updated_at = ?
            WHERE id = ? AND agent_id = ?;
            """
            var bStmt: OpaquePointer?
            defer { sqlite3_finalize(bStmt) }
            guard sqlite3_prepare_v2(db, catalogTailDecrementSQL, -1, &bStmt, nil) == SQLITE_OK else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
            }
            sqlite3_bind_int(bStmt, 1, shouldDecrementCatalogMessageCount ? 1 : 0)
            sqlite3_bind_double(bStmt, 2, rollbackTimestamp.timeIntervalSince1970)
            sqlite3_bind_text(bStmt, 3, conversationID.uuidString, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(bStmt, 4, agentId, -1, SQLite3Transient.destructor)
            guard try stepOnce(bStmt) == SQLITE_DONE else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Highest committed `sequence` for the conversation (`0` when there are no rows).
    func latestSequence(conversationID: UUID) throws -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COALESCE(MAX(sequence), 0) FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Inserts transcript rows present in `entries` but missing from the catalog (JSONL is authoritative).
    /// Does not advance ``conversations.updated_at`` — backfill must not reorder the sidebar on read/hydrate.
    func reconcileMissingRows(conversationID: UUID, authoritativeEntries: [SessionTranscriptEntry]) throws {
        let existing = try fetchMessageSequences(conversationID: conversationID)
        let sorted = authoritativeEntries.sorted { $0.sequence < $1.sequence }
        for entry in sorted where !existing.contains(entry.sequence) {
            try insertMessageBackfill(conversationID: conversationID, entry: entry)
        }
    }

    /// Catalog row insert for JSONL→SQLite backfill only (no conversation timestamp/head bump).
    private func insertMessageBackfill(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        guard let db else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            try insertMessageRow(db: db, conversationID: conversationID, entry: entry)
            if entry.type.countsTowardSessionCatalogMessageTotal {
                try incrementConversationMessageCount(db: db, conversationID: conversationID)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func fetchMessageSequences(conversationID: UUID) throws -> Set<Int> {
        guard let db else { return [] }
        let sql = "SELECT sequence FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        var out = Set<Int>()
        try forEachRow(stmt) { s in
            out.insert(Int(sqlite3_column_int(s, 0)))
        }
        return out
    }

    private func bumpConversationAfterMessage(db: OpaquePointer, conversationID: UUID, at: Date, entry: SessionTranscriptEntry) throws {
        if entry.type == .message || entry.type == .system {
            let headSQL = """
            UPDATE conversations SET updated_at = MAX(updated_at, ?), head_entry_id = ? WHERE id = ? AND agent_id = ?;
            """
            var headStmt: OpaquePointer?
            defer { sqlite3_finalize(headStmt) }
            guard sqlite3_prepare_v2(db, headSQL, -1, &headStmt, nil) == SQLITE_OK else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
            }
            sqlite3_bind_double(headStmt, 1, at.timeIntervalSince1970)
            sqlite3_bind_text(headStmt, 2, entry.entryId.rawValue, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(headStmt, 3, conversationID.uuidString, -1, SQLite3Transient.destructor)
            sqlite3_bind_text(headStmt, 4, agentId, -1, SQLite3Transient.destructor)
            guard try stepOnce(headStmt) == SQLITE_DONE else {
                throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
            }
        }
        guard entry.type.countsTowardSessionCatalogMessageTotal else { return }
        try incrementConversationMessageCount(db: db, conversationID: conversationID)
    }

    private static let catalogSelectColumns = """
    id, topic, description, message_count, updated_at, created_at, model_name, interaction_mode, mode_profile_id,
    source, trust_class, parent_conversation_id, fork_anchor_entry_id, head_entry_id, resource_json, current_run_id,
    last_active_at, resource_run_status, metadata_json, system_prompt, user_id, lifecycle_state, title, cwd,
    ended_at, end_reason, tool_call_count, total_prompt_tokens, total_completion_tokens, total_cost_minor_units,
    model_config_json, reasoning_tokens, cache_tokens, control_plane_revision, first_user_prompt, agent_id, transcript_integrity,
    conversation_lineage_kind, conversation_origin
    """

    private func catalogRecordFromStatement(_ stmt: OpaquePointer?) -> SessionCatalogRecord? {
        guard let stmt else { return nil }
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let topic = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
        let description = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2))
        let messageCount = Int(sqlite3_column_int(stmt, 3))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let modelName = String(cString: sqlite3_column_text(stmt, 6))
        let mode = String(cString: sqlite3_column_text(stmt, 7))
        let modeProfileID = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 8))
        let source = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 9))
        let trustClass = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10))
        let parentStr = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 11))
        let forkStr = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 12))
        let headStr = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 13))
        let resourceJSON = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 14))
        let currentRunStr = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 15))
        let lastActiveAt = sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        let resourceRunStatus = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 17))
        let metadataJSON = sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 18))
        let systemPrompt = sqlite3_column_type(stmt, 19) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 19))
        let userId = sqlite3_column_type(stmt, 20) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 20))
        let lifecycle = sqlite3_column_type(stmt, 21) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 21))
        let title = sqlite3_column_type(stmt, 22) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 22))
        let cwd = sqlite3_column_type(stmt, 23) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 23))
        let endedAt = sqlite3_column_type(stmt, 24) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 24))
        let endReason = sqlite3_column_type(stmt, 25) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 25))
        let toolCallCount = sqlite3_column_type(stmt, 26) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 26))
        let promptTok = sqlite3_column_type(stmt, 27) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 27))
        let completionTok = sqlite3_column_type(stmt, 28) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 28))
        let costMinor = sqlite3_column_type(stmt, 29) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 29))
        let modelConfig = sqlite3_column_type(stmt, 30) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 30))
        let reasoningTok = sqlite3_column_type(stmt, 31) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 31))
        let cacheTok = sqlite3_column_type(stmt, 32) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 32))
        let controlPlaneRevision = Int(sqlite3_column_int(stmt, 33))
        let firstPrompt = sqlite3_column_type(stmt, 34) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 34))
        let recordAgentId: String
        if sqlite3_column_type(stmt, 35) == SQLITE_NULL {
            recordAgentId = SessionPersistenceLayout.defaultAgentId
        } else {
            recordAgentId = String(cString: sqlite3_column_text(stmt, 35))
        }
        let integrityJSON = sqlite3_column_type(stmt, 36) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 36))
        let lineageRaw: String
        if sqlite3_column_count(stmt) > 37, sqlite3_column_type(stmt, 37) != SQLITE_NULL {
            lineageRaw = String(cString: sqlite3_column_text(stmt, 37))
        } else {
            lineageRaw = ConversationLineageKind.root.rawValue
        }
        let originRaw: String
        if sqlite3_column_count(stmt) > 38, sqlite3_column_type(stmt, 38) != SQLITE_NULL {
            originRaw = String(cString: sqlite3_column_text(stmt, 38))
        } else {
            originRaw = ConversationOrigin.user.rawValue
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        return SessionCatalogRecord(
            id: uuid,
            topic: topic,
            description: description,
            messageCount: messageCount,
            updatedAt: updatedAt,
            createdAt: createdAt,
            modelName: modelName,
            interactionModeRaw: mode,
            modeProfileID: modeProfileID,
            source: source,
            trustClass: trustClass,
            parentConversationID: parentStr.flatMap(UUID.init(uuidString:)),
            forkAnchorEntryID: forkStr.flatMap(SessionEntryID.init),
            headEntryId: headStr.flatMap(SessionEntryID.init),
            resourceJSON: resourceJSON,
            currentRunID: currentRunStr.flatMap(UUID.init(uuidString:)),
            lastActiveAt: lastActiveAt,
            resourceRunStatusRaw: resourceRunStatus,
            metadataJSON: metadataJSON,
            systemPrompt: systemPrompt,
            userID: userId,
            lifecycleStateRaw: lifecycle,
            title: title,
            cwd: cwd,
            endedAt: endedAt,
            endReason: endReason,
            toolCallCount: toolCallCount,
            totalPromptTokens: promptTok,
            totalCompletionTokens: completionTok,
            totalCostMinorUnits: costMinor,
            modelConfigJSON: modelConfig,
            reasoningTokens: reasoningTok,
            cacheTokens: cacheTok,
            controlPlaneRevision: controlPlaneRevision,
            firstUserPrompt: firstPrompt,
            agentId: recordAgentId,
            transcriptIntegrity: Self.decodeTranscriptIntegrityColumn(integrityJSON),
            lineageKind: ConversationLineageKind(rawValue: lineageRaw) ?? .root,
            origin: ConversationOrigin(rawValue: originRaw) ?? .user
        )
    }

    static func decodeTranscriptIntegrityColumn(_ json: String?) -> SessionTranscriptIntegrity? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionTranscriptIntegrity.self, from: data)
    }

    static func encodeTranscriptIntegrityColumn(_ integrity: SessionTranscriptIntegrity?) -> String? {
        guard let integrity else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(integrity) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setTranscriptIntegrity(conversationID: UUID, integrity: SessionTranscriptIntegrity?) throws {
        guard let db else { return }
        let sql = "UPDATE conversations SET transcript_integrity = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        bindOptionalText(stmt, 1, Self.encodeTranscriptIntegrityColumn(integrity))
        sqlite3_bind_text(stmt, 2, conversationID.uuidString, -1, SQLite3Transient.destructor)
        _ = try stepOnce(stmt)
    }

    func fetchTranscriptIntegrity(conversationID: UUID) throws -> SessionTranscriptIntegrity? {
        guard let db else { return nil }
        let sql = "SELECT transcript_integrity FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let json = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 0))
        return Self.decodeTranscriptIntegrityColumn(json)
    }

    func fetchCatalogConversations() throws -> [SessionCatalogRecord] {
        guard let db else { return [] }
        let sql = "SELECT \(Self.catalogSelectColumns) FROM conversations WHERE agent_id = ? ORDER BY updated_at DESC, id DESC;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, agentId, -1, SQLite3Transient.destructor)
        var rows: [SessionCatalogRecord] = []
        try forEachRow(stmt) { s in
            if let r = catalogRecordFromStatement(s) {
                rows.append(r)
            }
        }
        return rows
    }

    /// Keyset pagination contract: see ``SessionCatalogPage/nextCursor`` and ``SessionCatalogKeysetCursor``.
    func fetchCatalogConversationsPage(cursor: String?, limit: Int) throws -> SessionCatalogPage {
        guard let db else { return SessionCatalogPage(records: [], nextCursor: nil) }
        guard limit > 0 else { return SessionCatalogPage(records: [], nextCursor: nil) }

        let decodedCursor = SessionCatalogKeysetCursor.decode(cursor)
        let cursorTs = decodedCursor?.updatedAtUnixSeconds
        let cursorId = decodedCursor?.idString

        let sql: String
        if cursorTs != nil, cursorId != nil {
            sql = """
            SELECT \(Self.catalogSelectColumns) FROM conversations
            WHERE agent_id = ? AND ((updated_at < ?) OR (updated_at = ? AND id < ?))
            ORDER BY updated_at DESC, id DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT \(Self.catalogSelectColumns) FROM conversations
            WHERE agent_id = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT ?;
            """
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        if let ts = cursorTs, let cid = cursorId {
            sqlite3_bind_text(stmt, 1, agentId, -1, SQLite3Transient.destructor)
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_double(stmt, 3, ts)
            sqlite3_bind_text(stmt, 4, cid, -1, SQLite3Transient.destructor)
            sqlite3_bind_int(stmt, 5, Int32(limit))
        } else {
            sqlite3_bind_text(stmt, 1, agentId, -1, SQLite3Transient.destructor)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
        var rows: [SessionCatalogRecord] = []
        try forEachRow(stmt) { s in
            if let r = catalogRecordFromStatement(s) {
                rows.append(r)
            }
        }
        let next: String?
        if let last = rows.last {
            next = SessionCatalogKeysetCursor.encode(updatedAt: last.updatedAt, id: last.id)
        } else {
            next = nil
        }
        if rows.count < limit {
            return SessionCatalogPage(records: rows, nextCursor: nil)
        }
        return SessionCatalogPage(records: rows, nextCursor: next)
    }

    /// Filtered keyset page: predicates on optional filter fields, then same `(updated_at, id)` cursor as ``fetchCatalogConversationsPage``.
    ///
    /// **Semantics:** `since` applies to catalog **`updated_at`** (inclusive). Omitted filter fields do not constrain the query.
    /// **`agent_id`:** rows are stored per catalog install agent; if ``SessionConversationListFilter/agentId`` is set and differs from this catalog’s agent, the result is empty.
    private static func catalogVisibilitySQLClause(_ filter: ConversationCatalogVisibilityFilter) -> String {
        switch filter {
        case .primaryOnly:
            return " AND conversation_lineage_kind IN ('root', 'branch') AND conversation_origin = 'user'"
        case .automationsOnly:
            return " AND conversation_lineage_kind = 'root' AND conversation_origin = 'system'"
        case .catalogVisible:
            return " AND conversation_lineage_kind != 'subAgent'"
        case .allIncludingHidden:
            return ""
        }
    }

    func fetchCatalogConversationsFilteredPage(
        filter: SessionConversationListFilter,
        cursor: String?,
        limit: Int
    ) throws -> SessionCatalogPage {
        if let filterAgent = filter.agentId, filterAgent != agentId {
            return SessionCatalogPage(records: [], nextCursor: nil)
        }
        guard let db else { return SessionCatalogPage(records: [], nextCursor: nil) }
        guard limit > 0 else { return SessionCatalogPage(records: [], nextCursor: nil) }

        let decodedCursor = SessionCatalogKeysetCursor.decode(cursor)
        let cursorTs = decodedCursor?.updatedAtUnixSeconds
        let cursorId = decodedCursor?.idString

        var sql = "SELECT \(Self.catalogSelectColumns) FROM conversations WHERE agent_id = ?"
        if filter.source != nil { sql += " AND source = ?" }
        if filter.cwd != nil { sql += " AND cwd = ?" }
        if filter.lifecycleState != nil { sql += " AND lifecycle_state = ?" }
        if filter.since != nil { sql += " AND updated_at >= ?" }
        if filter.parentConversationID != nil { sql += " AND parent_conversation_id = ?" }
        sql += Self.catalogVisibilitySQLClause(filter.catalogVisibility)
        if cursorTs != nil, cursorId != nil {
            sql += " AND ((updated_at < ?) OR (updated_at = ? AND id < ?))"
        }
        sql += " ORDER BY updated_at DESC, id DESC LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        var bindSlot: Int32 = 1
        sqlite3_bind_text(stmt, bindSlot, agentId, -1, SQLite3Transient.destructor)
        bindSlot += 1
        if let s = filter.source {
            sqlite3_bind_text(stmt, bindSlot, s, -1, SQLite3Transient.destructor)
            bindSlot += 1
        }
        if let c = filter.cwd {
            sqlite3_bind_text(stmt, bindSlot, c, -1, SQLite3Transient.destructor)
            bindSlot += 1
        }
        if let l = filter.lifecycleState {
            sqlite3_bind_text(stmt, bindSlot, l, -1, SQLite3Transient.destructor)
            bindSlot += 1
        }
        if let since = filter.since {
            sqlite3_bind_double(stmt, bindSlot, since.timeIntervalSince1970)
            bindSlot += 1
        }
        if let parentID = filter.parentConversationID {
            sqlite3_bind_text(stmt, bindSlot, parentID.uuidString, -1, SQLite3Transient.destructor)
            bindSlot += 1
        }
        if let ts = cursorTs, let cid = cursorId {
            sqlite3_bind_double(stmt, bindSlot, ts)
            bindSlot += 1
            sqlite3_bind_double(stmt, bindSlot, ts)
            bindSlot += 1
            sqlite3_bind_text(stmt, bindSlot, cid, -1, SQLite3Transient.destructor)
            bindSlot += 1
        }
        sqlite3_bind_int(stmt, bindSlot, Int32(limit))

        var rows: [SessionCatalogRecord] = []
        try forEachRow(stmt) { s in
            if let r = catalogRecordFromStatement(s) {
                rows.append(r)
            }
        }
        let next: String?
        if let last = rows.last {
            next = SessionCatalogKeysetCursor.encode(updatedAt: last.updatedAt, id: last.id)
        } else {
            next = nil
        }
        if rows.count < limit {
            return SessionCatalogPage(records: rows, nextCursor: nil)
        }
        return SessionCatalogPage(records: rows, nextCursor: next)
    }

    func fetchCatalogConversation(id: UUID) throws -> SessionCatalogRecord? {
        guard let db else { return nil }
        let sql = "SELECT \(Self.catalogSelectColumns) FROM conversations WHERE id = ? AND agent_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return nil }
        return catalogRecordFromStatement(stmt)
    }

    /// Returns up to `limit` conversation ids with exact **case-sensitive** `title` (and optional lifecycle), for this catalog's `agent_id`.
    func fetchConversationIDsMatchingExactTitle(title: String, lifecycleState: String?, limit: Int = 3) throws -> [UUID] {
        guard let db else { return [] }
        let cap = max(1, min(limit, 8))
        let sql: String
        if lifecycleState != nil {
            sql = """
            SELECT id FROM conversations
            WHERE agent_id = ? AND title = ? AND lifecycle_state = ?
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id FROM conversations
            WHERE agent_id = ? AND title = ?
            LIMIT ?;
            """
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, agentId, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, title, -1, SQLite3Transient.destructor)
        if let lifecycleState {
            sqlite3_bind_text(stmt, 3, lifecycleState, -1, SQLite3Transient.destructor)
            sqlite3_bind_int(stmt, 4, Int32(cap))
        } else {
            sqlite3_bind_int(stmt, 3, Int32(cap))
        }
        var out: [UUID] = []
        try forEachRow(stmt) { s in
            let idStr = String(cString: sqlite3_column_text(s, 0))
            if let u = UUID(uuidString: idStr) { out.append(u) }
        }
        return out
    }

    func fetchChildConversationRecords(parentID: UUID) throws -> [SessionCatalogRecord] {
        guard let db else { return [] }
        let sql = """
        SELECT \(Self.catalogSelectColumns) FROM conversations
        WHERE parent_conversation_id = ? AND agent_id = ?
        ORDER BY created_at ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, parentID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        var rows: [SessionCatalogRecord] = []
        try forEachRow(stmt) { s in
            if let r = catalogRecordFromStatement(s) {
                rows.append(r)
            }
        }
        return rows
    }

    func applyCatalogLifecycle(
        conversationID: UUID,
        lifecycleStateRaw: String,
        endedAt: Date?,
        endReason: String?
    ) throws {
        guard let db else { return }
        let sql = """
        UPDATE conversations SET lifecycle_state = ?, ended_at = ?, end_reason = ?, updated_at = ?
        WHERE id = ? AND agent_id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, lifecycleStateRaw, -1, SQLite3Transient.destructor)
        if let endedAt {
            sqlite3_bind_double(stmt, 2, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        bindOptionalText(stmt, 3, endReason)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 6, agentId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func reopenCatalogConversation(conversationID: UUID) throws {
        try applyCatalogLifecycle(conversationID: conversationID, lifecycleStateRaw: ConversationLifecycleState.active.rawValue, endedAt: nil, endReason: nil)
    }

    func removeCatalogConversation(conversationID: UUID) throws {
        guard let db else { return }
        guard try conversationExists(id: conversationID) else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
        let sql = "DELETE FROM conversations WHERE id = ? AND agent_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
        guard sqlite3_changes(db) == 1 else {
            throw SessionPersistenceError.conversationNotFound(conversationID)
        }
    }

    /// Returns false when `control_plane_revision` did not match (caller maps to `SessionPersistenceError.controlPlaneRevisionConflict`).
    func applyCatalogTitle(conversationID: UUID, title: String, expectedControlPlaneRevision: Int, newRevision: Int) throws -> Bool {
        guard let db else { return false }
        let sql = """
        UPDATE conversations SET title = ?, topic = ?, control_plane_revision = ?, updated_at = ?
        WHERE id = ? AND control_plane_revision = ? AND agent_id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, title, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, title, -1, SQLite3Transient.destructor)
        sqlite3_bind_int(stmt, 3, Int32(newRevision))
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_int(stmt, 6, Int32(expectedControlPlaneRevision))
        sqlite3_bind_text(stmt, 7, agentId, -1, SQLite3Transient.destructor)
        try stepUntilDoneHandlingUnique(stmt, operation: "apply_catalog_title")
        return sqlite3_changes(db) == 1
    }

    /// Updates one catalog row using the supplied record payload.
    /// When `expectedControlPlaneRevision` is set, update is conditional on the current `control_plane_revision`.
    func updateCatalogConversationRecord(_ record: SessionCatalogRecord, expectedControlPlaneRevision: Int?) throws -> Bool {
        guard let db else { return false }
        let hasCAS = (expectedControlPlaneRevision != nil)
        let sql: String
        if hasCAS {
            sql = """
            UPDATE conversations SET
              topic = ?, description = ?, message_count = ?, updated_at = ?, created_at = ?,
              model_name = ?, interaction_mode = ?, mode_profile_id = ?,
              source = ?, trust_class = ?, parent_conversation_id = ?, fork_anchor_entry_id = ?, head_entry_id = ?,
              resource_json = ?, current_run_id = ?, last_active_at = ?, resource_run_status = ?, metadata_json = ?,
              system_prompt = ?, user_id = ?, lifecycle_state = ?, title = ?, cwd = ?, ended_at = ?, end_reason = ?,
              tool_call_count = ?, total_prompt_tokens = ?, total_completion_tokens = ?, total_cost_minor_units = ?,
              model_config_json = ?, reasoning_tokens = ?, cache_tokens = ?, control_plane_revision = ?, first_user_prompt = ?, agent_id = ?,
              conversation_lineage_kind = ?, conversation_origin = ?
            WHERE id = ? AND agent_id = ? AND control_plane_revision = ?;
            """
        } else {
            sql = """
            UPDATE conversations SET
              topic = ?, description = ?, message_count = ?, updated_at = ?, created_at = ?,
              model_name = ?, interaction_mode = ?, mode_profile_id = ?,
              source = ?, trust_class = ?, parent_conversation_id = ?, fork_anchor_entry_id = ?, head_entry_id = ?,
              resource_json = ?, current_run_id = ?, last_active_at = ?, resource_run_status = ?, metadata_json = ?,
              system_prompt = ?, user_id = ?, lifecycle_state = ?, title = ?, cwd = ?, ended_at = ?, end_reason = ?,
              tool_call_count = ?, total_prompt_tokens = ?, total_completion_tokens = ?, total_cost_minor_units = ?,
              model_config_json = ?, reasoning_tokens = ?, cache_tokens = ?, control_plane_revision = ?, first_user_prompt = ?, agent_id = ?,
              conversation_lineage_kind = ?, conversation_origin = ?
            WHERE id = ? AND agent_id = ?;
            """
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        bindOptionalText(stmt, 1, record.topic)
        bindOptionalText(stmt, 2, record.description)
        sqlite3_bind_int(stmt, 3, Int32(record.messageCount))
        sqlite3_bind_double(stmt, 4, record.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, record.modelName, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 7, record.interactionModeRaw, -1, SQLite3Transient.destructor)
        bindOptionalText(stmt, 8, record.modeProfileID)
        bindOptionalText(stmt, 9, record.source)
        bindOptionalText(stmt, 10, record.trustClass)
        bindOptionalText(stmt, 11, record.parentConversationID?.uuidString)
        bindOptionalText(stmt, 12, record.forkAnchorEntryID?.rawValue)
        bindOptionalText(stmt, 13, record.headEntryId?.rawValue)
        bindOptionalText(stmt, 14, record.resourceJSON)
        bindOptionalText(stmt, 15, record.currentRunID?.uuidString)
        if let lastActiveAt = record.lastActiveAt {
            sqlite3_bind_double(stmt, 16, lastActiveAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 16)
        }
        bindOptionalText(stmt, 17, record.resourceRunStatusRaw)
        bindOptionalText(stmt, 18, record.metadataJSON)
        bindOptionalText(stmt, 19, record.systemPrompt)
        bindOptionalText(stmt, 20, record.userID)
        bindOptionalText(stmt, 21, record.lifecycleStateRaw)
        bindOptionalText(stmt, 22, record.title)
        bindOptionalText(stmt, 23, record.cwd)
        if let endedAt = record.endedAt {
            sqlite3_bind_double(stmt, 24, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 24)
        }
        bindOptionalText(stmt, 25, record.endReason)
        bindOptionalInt(stmt, 26, record.toolCallCount)
        bindOptionalInt(stmt, 27, record.totalPromptTokens)
        bindOptionalInt(stmt, 28, record.totalCompletionTokens)
        bindOptionalInt(stmt, 29, record.totalCostMinorUnits)
        bindOptionalText(stmt, 30, record.modelConfigJSON)
        bindOptionalInt(stmt, 31, record.reasoningTokens)
        bindOptionalInt(stmt, 32, record.cacheTokens)
        sqlite3_bind_int(stmt, 33, Int32(record.controlPlaneRevision))
        bindOptionalText(stmt, 34, record.firstUserPrompt)
        sqlite3_bind_text(stmt, 35, record.agentId, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 36, record.lineageKind.rawValue, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 37, record.origin.rawValue, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 38, record.id.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 39, agentId, -1, SQLite3Transient.destructor)
        if let expectedControlPlaneRevision {
            sqlite3_bind_int(stmt, 40, Int32(expectedControlPlaneRevision))
        }
        try stepUntilDoneHandlingUnique(stmt, operation: "update_catalog_conversation_record")
        return sqlite3_changes(db) == 1
    }

    /// Sets catalog `head_entry_id` with optional optimistic concurrency on `control_plane_revision`.
    func setConversationHeadEntryId(
        conversationID: UUID,
        entryId: SessionEntryID,
        expectedControlPlaneRevision: Int?
    ) throws -> Bool {
        guard let db else { return false }
        let sql: String
        if expectedControlPlaneRevision != nil {
            sql = """
            UPDATE conversations SET head_entry_id = ?, updated_at = ?, control_plane_revision = control_plane_revision + 1
            WHERE id = ? AND agent_id = ? AND control_plane_revision = ?;
            """
        } else {
            sql = """
            UPDATE conversations SET head_entry_id = ?, updated_at = ?
            WHERE id = ? AND agent_id = ?;
            """
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, entryId.rawValue, -1, SQLite3Transient.destructor)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 4, agentId, -1, SQLite3Transient.destructor)
        if let expectedControlPlaneRevision {
            sqlite3_bind_int(stmt, 5, Int32(expectedControlPlaneRevision))
        }
        try stepUntilDoneHandlingUnique(stmt, operation: "set_conversation_head_entry_id")
        return sqlite3_changes(db) == 1
    }

    func coalesceFirstUserPrompt(conversationID: UUID, text: String) throws {
        guard let db else { return }
        let sql = """
        UPDATE conversations SET first_user_prompt = COALESCE(NULLIF(first_user_prompt, ''), ?), updated_at = ?
        WHERE id = ? AND agent_id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, text, -1, SQLite3Transient.destructor)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 4, agentId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func fetchFirstUserPrompt(conversationID: UUID) throws -> String? {
        try fetchCatalogConversation(id: conversationID)?.firstUserPrompt
    }

    func searchTranscriptMessages(matchSQL: String, agentId: String?, conversationID: UUID?, limit: Int) throws -> [SessionMessageSearchHit] {
        guard let db else { return [] }
        guard limit > 0 else { return [] }
        let trimmed = matchSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let sqlEscape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let hl0 = sqlEscape(SessionFTS5SearchConstants.snippetHighlightStart)
        let hl1 = sqlEscape(SessionFTS5SearchConstants.snippetHighlightEnd)
        let ell = sqlEscape(SessionFTS5SearchConstants.snippetEllipsis)
        let tok = SessionFTS5SearchConstants.snippetTokenCount

        var sql = """
        SELECT m.conversation_id, m.id, m.sequence, m.timestamp,
          snippet(messages_fts, 0, '\(hl0)', '\(hl1)', '\(ell)', \(tok)),
          bm25(messages_fts)
        FROM messages_fts
        JOIN messages m ON m.rowid = messages_fts.rowid
        """
        if agentId != nil {
            sql += "\nJOIN conversations c ON c.id = m.conversation_id\n"
        } else {
            sql += "\n"
        }
        sql += "WHERE messages_fts MATCH ?\n"
        if conversationID != nil {
            sql += "AND m.conversation_id = ?\n"
        }
        if agentId != nil {
            sql += "AND c.agent_id = ?\n"
        }
        sql += "ORDER BY bm25(messages_fts) ASC, m.conversation_id ASC, m.sequence ASC, m.id ASC\nLIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        var bind: Int32 = 1
        sqlite3_bind_text(stmt, bind, trimmed, -1, SQLite3Transient.destructor)
        bind += 1
        if let conversationID {
            sqlite3_bind_text(stmt, bind, conversationID.uuidString, -1, SQLite3Transient.destructor)
            bind += 1
        }
        if let agentId {
            sqlite3_bind_text(stmt, bind, agentId, -1, SQLite3Transient.destructor)
            bind += 1
        }
        sqlite3_bind_int(stmt, bind, Int32(limit))

        var rows: [SessionMessageSearchHit] = []
        try forEachRow(stmt) { s in
            let cidStr = String(cString: sqlite3_column_text(s, 0))
            let idStr = String(cString: sqlite3_column_text(s, 1))
            let seq = Int(sqlite3_column_int(s, 2))
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(s, 3))
            let snippetPtr = sqlite3_column_text(s, 4)
            let snippet = snippetPtr.map { String(cString: $0) } ?? ""
            let score = sqlite3_column_double(s, 5)
            guard let cid = UUID(uuidString: cidStr), let eid = SessionEntryID(idStr) else { return }
            rows.append(
                SessionMessageSearchHit(
                    conversationID: cid,
                    entryId: eid,
                    sequence: seq,
                    snippet: snippet,
                    score: score,
                    timestamp: ts
                )
            )
        }
        return rows
    }

    func fetchTranscriptEntry(conversationID: UUID, entryId: SessionEntryID) throws -> SessionTranscriptEntry? {
        guard let db else { return nil }
        let sql = """
        SELECT sequence, id, role, payload_json, timestamp, parent_entry_id FROM messages
        WHERE conversation_id = ? AND id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, entryId.rawValue, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return nil }
        return transcriptEntryFromStatement(stmt)
    }

    func fetchChildTranscriptEntries(conversationID: UUID, parentEntryId: SessionEntryID) throws -> [SessionTranscriptEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT sequence, id, role, payload_json, timestamp, parent_entry_id FROM messages
        WHERE conversation_id = ? AND parent_entry_id = ?
        ORDER BY sequence ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, parentEntryId.rawValue, -1, SQLite3Transient.destructor)
        var rows: [SessionTranscriptEntry] = []
        try forEachRow(stmt) { s in
            if let e = transcriptEntryFromStatement(s) {
                rows.append(e)
            }
        }
        return rows
    }

    private func transcriptEntryFromStatement(_ stmt: OpaquePointer?) -> SessionTranscriptEntry? {
        guard let stmt else { return nil }
        let sequence = Int(sqlite3_column_int(stmt, 0))
        let idStr = String(cString: sqlite3_column_text(stmt, 1))
        let roleStr = String(cString: sqlite3_column_text(stmt, 2))
        let payload = String(cString: sqlite3_column_text(stmt, 3))
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let parentEntryId: SessionEntryID?
        if sqlite3_column_type(stmt, 5) == SQLITE_NULL {
            parentEntryId = nil
        } else {
            let ps = String(cString: sqlite3_column_text(stmt, 5))
            parentEntryId = SessionEntryID(ps)
        }
        guard let eid = SessionEntryID(idStr) else { return nil }
        let type = SessionTranscriptEntryType.decoding(from: roleStr)
        let rawHint: String? = (type == .custom) ? roleStr : nil
        return SessionTranscriptEntry(
            sequence: sequence,
            entryId: eid,
            parentEntryId: parentEntryId,
            type: type,
            harnessTypeRaw: rawHint,
            timestamp: ts,
            payloadJSON: payload
        )
    }

    func transcriptRowCount(conversationID: UUID) throws -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, conversationID.uuidString, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func fetchMessages(conversationID: UUID, fromSequence: Int?, toSequence: Int? = nil) throws -> [SessionTranscriptEntry] {
        guard let db else { return [] }
        var clauses = ["conversation_id = ?"]
        if fromSequence != nil { clauses.append("sequence >= ?") }
        if toSequence != nil { clauses.append("sequence <= ?") }
        let sql = """
        SELECT sequence, id, role, payload_json, timestamp, parent_entry_id FROM messages
        WHERE \(clauses.joined(separator: " AND ")) ORDER BY sequence ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, conversationID.uuidString, -1, SQLite3Transient.destructor)
        bindIndex += 1
        if let from = fromSequence {
            sqlite3_bind_int(stmt, bindIndex, Int32(from))
            bindIndex += 1
        }
        if let to = toSequence {
            sqlite3_bind_int(stmt, bindIndex, Int32(to))
        }
        var rows: [SessionTranscriptEntry] = []
        try forEachRow(stmt) { s in
            if let e = transcriptEntryFromStatement(s) {
                rows.append(e)
            }
        }
        return rows
    }

    /// Non-blocking WAL truncation hint (safe with concurrent readers).
    func passiveWalCheckpoint() throws {
        try exec("PRAGMA wal_checkpoint(PASSIVE);")
    }

    func vacuum() throws {
        try exec("VACUUM;")
    }

    func conversationExists(id: UUID) throws -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM conversations WHERE id = ? AND agent_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        return try stepOnce(stmt) == SQLITE_ROW
    }

    // MARK: - P3c harness tasks / cron catch-up

    func fetchHarnessTaskRunByIdempotencyKey(_ key: String) throws -> SessionHarnessTaskRunRecord? {
        guard let db else { return nil }
        let sql = """
        SELECT job_id, run_id, payload, created_at, idempotency_key
        FROM harness_tasks WHERE idempotency_key = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return nil }
        return harnessTaskRunFromRow(stmt: stmt)
    }

    func insertHarnessTaskPending(jobId: String, runId: UUID, payload: Data, idempotencyKey: String?) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO harness_tasks (job_id, run_id, idempotency_key, payload, status, created_at, delivered_at)
        VALUES (?, ?, ?, ?, 'pending', ?, NULL);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, jobId, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, runId.uuidString, -1, SQLite3Transient.destructor)
        if let idempotencyKey {
            sqlite3_bind_text(stmt, 3, idempotencyKey, -1, SQLite3Transient.destructor)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        try payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: 0, operation: "harness_task_payload_bind")
            }
            sqlite3_bind_blob(stmt, 4, base, Int32(payload.count), SQLite3Transient.destructor)
        }
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func fetchLatestPendingHarnessTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord? {
        guard let db else { return nil }
        let sql = """
        SELECT job_id, run_id, payload, created_at, idempotency_key
        FROM harness_tasks
        WHERE job_id = ? AND status = 'pending'
        ORDER BY created_at ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, jobId, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return nil }
        return harnessTaskRunFromRow(stmt: stmt)
    }

    func markHarnessTaskDelivered(runId: UUID) throws {
        guard let db else { return }
        let sql = """
        UPDATE harness_tasks SET status = 'delivered', delivered_at = ?
        WHERE run_id = ? AND status = 'pending';
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, runId.uuidString, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    // MARK: - Gap 7 (state_meta + tasks registry)

    func upsertStateMeta(key: String, value: String) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO state_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLite3Transient.destructor)
        sqlite3_bind_text(stmt, 2, value, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func fetchStateMeta(key: String) throws -> String? {
        guard let db else { return nil }
        let sql = "SELECT value FROM state_meta WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLite3Transient.destructor)
        guard try stepOnce(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func upsertScheduledTaskDefinitionRow(taskId: String, agentId: String?, payload: Data) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO tasks (task_id, agent_id, payload, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(task_id) DO UPDATE SET
          agent_id = excluded.agent_id,
          payload = excluded.payload,
          updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        sqlite3_bind_text(stmt, 1, taskId, -1, SQLite3Transient.destructor)
        if let agentId {
            sqlite3_bind_text(stmt, 2, agentId, -1, SQLite3Transient.destructor)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        try payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: 0, operation: "tasks_payload_bind")
            }
            sqlite3_bind_blob(stmt, 3, base, Int32(payload.count), SQLite3Transient.destructor)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        guard try stepOnce(stmt) == SQLITE_DONE else {
            throw SQLiteSessionCatalogError.stepFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_step")
        }
    }

    func fetchScheduledTaskDefinitionPayloads(agentId: String?) throws -> [Data] {
        guard let db else { return [] }
        let sql: String
        if agentId == nil {
            sql = "SELECT payload FROM tasks ORDER BY task_id ASC;"
        } else {
            sql = "SELECT payload FROM tasks WHERE agent_id = ? ORDER BY task_id ASC;"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteSessionCatalogError.prepareFailed(sqliteCode: sqliteExtendedCode(), operation: "sql_prepare")
        }
        if let agentId {
            sqlite3_bind_text(stmt, 1, agentId, -1, SQLite3Transient.destructor)
        }
        var out: [Data] = []
        try forEachRow(stmt) { s in
            let blobLen = sqlite3_column_bytes(s, 0)
            let blobPtr = sqlite3_column_blob(s, 0)
            if let blobPtr, blobLen > 0 {
                out.append(Data(bytes: blobPtr, count: Int(blobLen)))
            } else {
                out.append(Data())
            }
        }
        return out
    }

    private func harnessTaskRunFromRow(stmt: OpaquePointer?) -> SessionHarnessTaskRunRecord? {
        guard let stmt else { return nil }
        let jobId = String(cString: sqlite3_column_text(stmt, 0))
        let runStr = String(cString: sqlite3_column_text(stmt, 1))
        guard let runId = UUID(uuidString: runStr) else { return nil }
        let blobLen = sqlite3_column_bytes(stmt, 2)
        let blobPtr = sqlite3_column_blob(stmt, 2)
        let payload: Data
        if let blobPtr, blobLen > 0 {
            payload = Data(bytes: blobPtr, count: Int(blobLen))
        } else {
            payload = Data()
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let idem: String?
        if sqlite3_column_type(stmt, 4) == SQLITE_NULL {
            idem = nil
        } else {
            idem = String(cString: sqlite3_column_text(stmt, 4))
        }
        return SessionHarnessTaskRunRecord(runId: runId, jobId: jobId, createdAt: createdAt, payload: payload, idempotencyKey: idem)
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLite3Transient.destructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
