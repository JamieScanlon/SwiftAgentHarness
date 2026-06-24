import Foundation
@testable import SwiftAgentHarness
import SQLite3
import SwiftAgentKit
import Testing

@Suite("Harness session persistence Gap 11 (typed errors + boundary mapping)")
struct SessionPersistenceGap11Tests {
    @Test func appendTaskRunIdempotentReplayReturnsSameRunId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap11-idem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let p1 = Data("a".utf8)
        let id1 = try local.appendTaskRun(jobId: "job", payload: p1, idempotencyKey: "idem-1")
        let id2 = try local.appendTaskRun(jobId: "job", payload: p1, idempotencyKey: "idem-1")
        #expect(id1 == id2)
    }

    @Test func appendTaskRunIdempotencyConflictThrowsTypedError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap11-hit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        _ = try local.appendTaskRun(jobId: "job", payload: Data("a".utf8), idempotencyKey: "idem-x")
        var caught: SessionPersistenceError?
        do {
            _ = try local.appendTaskRun(jobId: "other", payload: Data("b".utf8), idempotencyKey: "idem-x")
        } catch let e as SessionPersistenceError {
            caught = e
        }
        guard case .idempotencyHit(let key, _) = caught else {
            Issue.record("expected idempotencyHit, got \(String(describing: caught))")
            return
        }
        #expect(key == "idem-x")
    }

    @Test func catalogSchemaNewerThanBinaryMapsToSchemaUpgradeRequired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap11-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LocalHarnessSessionPersistence(root: root)
        let dbURL = SessionPersistenceLayout.catalogURL(root: root)
        let unsupportedVersion = SQLiteSessionCatalog.kSupportedCatalogSchemaVersion + 1
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pdb = db else {
            Issue.record("sqlite open failed")
            return
        }
        defer { sqlite3_close(pdb) }
        let sql = "UPDATE schema_version SET version = \(unsupportedVersion) WHERE id = 1;"
        guard sqlite3_exec(pdb, sql, nil, nil, nil) == SQLITE_OK else {
            Issue.record("sqlite update failed")
            return
        }
        do {
            _ = try LocalHarnessSessionPersistence(root: root)
            Issue.record("expected open to fail")
        } catch let e as SessionPersistenceError {
            guard case .schemaUpgradeRequired(let found, let supported) = e else {
                Issue.record("expected schemaUpgradeRequired, got \(e)")
                return
            }
            #expect(found == unsupportedVersion)
            #expect(supported == SQLiteSessionCatalog.kSupportedCatalogSchemaVersion)
        }
    }

    @Test func strictLockWithoutHoldThrowsLockNotHeld() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap11-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try HarnessEnvironmentOverride.$overrides.withValue(["SAH_SESSION_ENFORCE_TRANSCRIPT_LOCK": "1"]) {
            let local = try LocalHarnessSessionPersistence(root: root)
            let cid = UUID()
            var row = SessionCatalogRecord(
                id: cid,
                topic: "t",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
            row.agentId = SessionPersistenceLayout.defaultAgentId
            try local.bootstrapEmptyConversation(row)

            let entry = SessionTranscriptEntry(
                sequence: 1,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: Date(),
                payloadJSON: #"{"role":"user","content":"hi","id":"\#(UUID().uuidString)"}"#
            )
            #expect(throws: SessionPersistenceError.self) {
                try local.appendMirroredTranscriptEntry(conversationID: cid, entry: entry)
            }
        }
    }

    @Test func heldRegistryTracksLockProcessWideNotPerThread() async {
        let conversationID = UUID()
        TranscriptWriteLockHeldRegistry.incrementHeld(conversationID: conversationID)
        defer { TranscriptWriteLockHeldRegistry.decrementHeld(conversationID: conversationID) }

        let visibleOnOtherThread = await Task.detached {
            TranscriptWriteLockHeldRegistry.isWriteLockHeld(conversationID: conversationID)
        }.value
        #expect(visibleOnOtherThread)
        #expect(TranscriptWriteLockHeldRegistry.isWriteLockHeld(conversationID: conversationID))
    }

    @Test func mappedCatalogErrorOmitsSqliteErrmsgEnglish() throws {
        let err = SessionCatalogErrorMapping.persistenceError(
            from: SQLiteSessionCatalogError.prepareFailed(sqliteCode: 1, operation: "sql_prepare")
        )
        guard case .catalogStoreFailed(let op, let code) = err else {
            Issue.record("expected catalogStoreFailed")
            return
        }
        #expect(op == "sql_prepare")
        #expect(code == Int32(1))
    }
}

