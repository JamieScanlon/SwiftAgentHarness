import Foundation
import SQLite3
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Catalog schema v16 — drop legacy agent_phase column")
struct SessionCatalogSchemaV16Tests {

    @Test func legacyAgentPhaseColumnIsDroppedAndInsertsSucceed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-v16-agent-phase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer {
            if let db { sqlite3_close(db) }
        }
        #expect(sqlite3_exec(db, "CREATE TABLE schema_version (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO schema_version (id, version) VALUES (1, 15);", nil, nil, nil) == SQLITE_OK)
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
                  agent_phase TEXT NOT NULL,
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
                  transcript_integrity TEXT
                );
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        #expect(
            sqlite3_exec(
                db,
                """
                CREATE TABLE messages (
                  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                  id TEXT NOT NULL,
                  conversation_id TEXT NOT NULL,
                  sequence INTEGER NOT NULL,
                  role TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  timestamp REAL NOT NULL,
                  parent_entry_id TEXT,
                  content TEXT NOT NULL DEFAULT '',
                  UNIQUE(conversation_id, sequence),
                  FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
                );
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )

        let catalog = try SQLiteSessionCatalog(fileURL: url)
        #expect(try catalog.exposedSchemaVersionForRecoveryIndex() == 18)

        let now = Date(timeIntervalSince1970: 70_000)
        let record = SessionCatalogRecord(
            id: UUID(),
            topic: "post-migration",
            description: nil,
            messageCount: 0,
            updatedAt: now,
            createdAt: now,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        try catalog.insertConversation(record)
        let rows = try catalog.fetchCatalogConversations()
        #expect(rows.count == 1)
        #expect(rows[0].topic == "post-migration")
    }
}
