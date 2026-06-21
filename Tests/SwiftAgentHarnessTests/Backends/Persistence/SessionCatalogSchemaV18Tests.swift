import Foundation
import SQLite3
@testable import SwiftAgentHarness
import Testing

@Suite("Catalog schema v18 — control_plane_revision column rename")
struct SessionCatalogSchemaV18Tests {

    private func conversationsHasColumn(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(conversations);", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(stmt, 1))
            if colName == name { return true }
        }
        return false
    }

    private func makeV17Catalog(at url: URL) -> (db: OpaquePointer, conversationID: UUID) {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = handle!
        #expect(sqlite3_exec(db, "CREATE TABLE schema_version (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO schema_version (id, version) VALUES (1, 17);", nil, nil, nil) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                db,
                """
                CREATE TABLE conversations (
                  id TEXT PRIMARY KEY,
                  topic TEXT,
                  description TEXT,
                  message_count INTEGER NOT NULL DEFAULT 0,
                  updated_at REAL NOT NULL,
                  created_at REAL NOT NULL,
                  model_name TEXT NOT NULL,
                  interaction_mode TEXT NOT NULL,
                  source TEXT,
                  trust_class TEXT,
                  parent_conversation_id TEXT,
                  fork_anchor_entry_id TEXT,
                  user_id TEXT,
                  lifecycle_state TEXT,
                  title TEXT,
                  cwd TEXT,
                  ended_at REAL,
                  end_reason TEXT,
                  tool_call_count INTEGER,
                  total_prompt_tokens INTEGER,
                  total_completion_tokens INTEGER,
                  total_cost_minor_units INTEGER,
                  model_config_json TEXT,
                  reasoning_tokens INTEGER,
                  cache_tokens INTEGER,
                  title_version INTEGER NOT NULL DEFAULT 0,
                  first_user_prompt TEXT,
                  agent_id TEXT NOT NULL DEFAULT 'default',
                  mode_profile_id TEXT,
                  head_entry_id TEXT,
                  resource_json TEXT,
                  current_run_id TEXT,
                  last_active_at REAL,
                  resource_run_status TEXT,
                  metadata_json TEXT,
                  system_prompt TEXT,
                  transcript_integrity TEXT,
                  conversation_lineage_kind TEXT NOT NULL DEFAULT 'root',
                  conversation_origin TEXT NOT NULL DEFAULT 'user'
                );
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        let cid = UUID()
        #expect(
            sqlite3_exec(
                db,
                """
                INSERT INTO conversations (id, topic, description, message_count, updated_at, created_at, model_name, interaction_mode, title_version)
                VALUES ('\(cid.uuidString)', 'T', NULL, 0, 1, 1, 'm', 'chat', 3);
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        return (db, cid)
    }

    @Test func freshStoreOpensAtSchemaV18WithControlPlaneRevisionColumn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-v18-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        #expect(try local.catalogSchemaVersion() == SQLiteSessionCatalog.kSupportedCatalogSchemaVersion)
        #expect(try local.catalogSchemaVersion() == 18)

        let catalogURL = root.appendingPathComponent("catalog.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(catalogURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let handle = try #require(db)
        #expect(conversationsHasColumn(db: handle, name: "control_plane_revision"))
        #expect(!conversationsHasColumn(db: handle, name: "title_version"))
    }

    @Test func migratesV17TitleVersionToControlPlaneRevision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-v18-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")

        let (db, conversationID) = makeV17Catalog(at: url)
        defer { sqlite3_close(db) }
        #expect(conversationsHasColumn(db: db, name: "title_version"))

        let catalog = try SQLiteSessionCatalog(fileURL: url)
        #expect(try catalog.exposedSchemaVersionForRecoveryIndex() == 18)

        var reopened: OpaquePointer?
        #expect(sqlite3_open(url.path, &reopened) == SQLITE_OK)
        defer { sqlite3_close(reopened) }
        let handle = try #require(reopened)
        #expect(conversationsHasColumn(db: handle, name: "control_plane_revision"))
        #expect(!conversationsHasColumn(db: handle, name: "title_version"))

        let record = try #require(try catalog.fetchCatalogConversation(id: conversationID))
        #expect(record.controlPlaneRevision == 3)
    }
}
