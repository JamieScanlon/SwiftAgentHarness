import Foundation
import SQLite3
@testable import SwiftAgentHarness
import Testing

@Suite("Catalog schema v17 — conversation lineage and origin columns")
struct SessionCatalogSchemaV17Tests {

    private func makeV16Catalog(at url: URL) -> OpaquePointer {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = handle!
        #expect(sqlite3_exec(db, "CREATE TABLE schema_version (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO schema_version (id, version) VALUES (1, 16);", nil, nil, nil) == SQLITE_OK)
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
        return db
    }

    private func insertConversation(
        db: OpaquePointer,
        id: UUID,
        interactionMode: String,
        modeProfileID: String?,
        topic: String?,
        parentID: UUID?,
        metadataJSON: String?
    ) {
        let parent = parentID.map { "'\($0.uuidString.lowercased())'" } ?? "NULL"
        let profile = modeProfileID.map { "'\($0)'" } ?? "NULL"
        let topicSQL = topic.map { "'\($0)'" } ?? "NULL"
        let metadata = metadataJSON.map { "'\($0)'" } ?? "NULL"
        #expect(
            sqlite3_exec(
                db,
                """
                INSERT INTO conversations (id, topic, description, message_count, updated_at, created_at, model_name, interaction_mode, mode_profile_id, metadata_json, parent_conversation_id)
                VALUES ('\(id.uuidString)', \(topicSQL), NULL, 0, 1, 1, 'm', '\(interactionMode)', \(profile), \(metadata), \(parent));
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
    }

    @Test func migratesV16ToV17AndBackfillsMachineSubAgentRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-v17-kind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")

        let parentID = UUID()
        let subAgentDepthID = UUID()
        let memoryExtractionID = UUID()
        let triggerDelegateID = UUID()
        let userBranchID = UUID()

        let db = makeV16Catalog(at: url)
        defer { sqlite3_close(db) }

        insertConversation(
            db: db,
            id: subAgentDepthID,
            interactionMode: "agent",
            modeProfileID: nil,
            topic: "worker",
            parentID: parentID,
            metadataJSON: #"{"subAgentDepth":1}"#
        )
        insertConversation(
            db: db,
            id: memoryExtractionID,
            interactionMode: "agent",
            modeProfileID: "memory-extraction",
            topic: "memory-extraction",
            parentID: parentID,
            metadataJSON: nil
        )
        insertConversation(
            db: db,
            id: triggerDelegateID,
            interactionMode: "agent",
            modeProfileID: "trigger-delegate",
            topic: "trigger-delegate",
            parentID: parentID,
            metadataJSON: nil
        )
        insertConversation(
            db: db,
            id: userBranchID,
            interactionMode: "chat",
            modeProfileID: nil,
            topic: "fork",
            parentID: parentID,
            metadataJSON: nil
        )

        let catalog = try SQLiteSessionCatalog(fileURL: url)
        #expect(try catalog.exposedSchemaVersionForRecoveryIndex() == 18)

        let subAgentDepth = try #require(try catalog.fetchCatalogConversation(id: subAgentDepthID))
        #expect(subAgentDepth.lineageKind == .subAgent)
        #expect(subAgentDepth.origin == .system)

        let memoryExtraction = try #require(try catalog.fetchCatalogConversation(id: memoryExtractionID))
        #expect(memoryExtraction.lineageKind == .subAgent)
        #expect(memoryExtraction.origin == .system)

        let triggerDelegate = try #require(try catalog.fetchCatalogConversation(id: triggerDelegateID))
        #expect(triggerDelegate.lineageKind == .subAgent)
        #expect(triggerDelegate.origin == .system)

        let userBranch = try #require(try catalog.fetchCatalogConversation(id: userBranchID))
        #expect(userBranch.lineageKind == .branch)
        #expect(userBranch.origin == .user)

        let reopened = try SQLiteSessionCatalog(fileURL: url)
        #expect(try reopened.exposedSchemaVersionForRecoveryIndex() == 18)
        let unchanged = try #require(try reopened.fetchCatalogConversation(id: memoryExtractionID))
        #expect(unchanged.lineageKind == .subAgent)
        #expect(unchanged.origin == .system)
    }
}
