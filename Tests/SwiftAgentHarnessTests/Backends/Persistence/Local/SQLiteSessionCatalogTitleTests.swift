import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("SQLite session catalog title uniqueness (Gap 3)")
struct SQLiteSessionCatalogTitleTests {
    @Test func duplicateNonNullTitleThrowsOnSecondInsert() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("catalog.sqlite")
        let cat = try SQLiteSessionCatalog(fileURL: url)
        let t = Date(timeIntervalSince1970: 60_000)
        let r1 = SessionCatalogRecord(
            id: UUID(),
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        var r2 = SessionCatalogRecord(
            id: UUID(),
            topic: "T",
            description: nil,
            messageCount: 0,
            updatedAt: t,
            createdAt: t,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        r2.id = UUID()
        try cat.insertConversation(r1)
        #expect(throws: SQLiteSessionCatalogError.self) {
            try cat.insertConversation(r2)
        }
    }

    @Test func resolveAndLineageThroughLocalPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalHarnessSessionPersistence(root: dir)
        let t = Date(timeIntervalSince1970: 90_000)
        let p = SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "s",
            trustClass: nil,
            parentConversationID: nil,
            forkAnchorMessageID: nil,
            cwd: nil,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
            title: "Root",
            topic: nil,
            description: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: t
        )
        let row1 = try local.createConversation(p)
        var q = p
        q.title = "Root #1"
        q.createdAt = t.addingTimeInterval(10)
        let row2 = try local.createConversation(q)
        let resolved = try local.resolveSessionByTitle("Root", lifecycleState: ConversationLifecycleState.active.rawValue)
        #expect(resolved != nil)
        let lineage = try local.nextSessionTitleInLineage(forTitle: "Root", lifecycleState: nil)
        #expect(lineage == "Root #1")
        let latestId = try local.resolveLatestSessionIDInLineage(forTitle: "Root", lifecycleState: nil)
        #expect(latestId == row2.id)
        #expect(latestId != row1.id)
    }

    @Test func resolveSessionByTitleMatchesNfcAndNfdKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-nfc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalHarnessSessionPersistence(root: dir)
        let t = Date(timeIntervalSince1970: 91_000)
        let nfc = "caf\u{00E9}"
        let p = SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "s",
            trustClass: nil,
            parentConversationID: nil,
            forkAnchorMessageID: nil,
            cwd: nil,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
            title: nfc,
            topic: nil,
            description: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: t
        )
        let row = try local.createConversation(p)
        let nfd = "cafe\u{0301}"
        let resolved = try local.resolveSessionByTitle(nfd, lifecycleState: ConversationLifecycleState.active.rawValue)
        #expect(resolved == row.id)
    }

    @Test func updateSessionConversationPatchNormalizesTitleAndTopic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-patch-nfc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalHarnessSessionPersistence(root: dir)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "Seed",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
        )
        let nfd = "cafe\u{0301}"
        let nfc = "caf\u{00E9}"
        var patch = SessionConversationUpdatePatch()
        patch.title = .set(nfd)
        patch.topic = .set(nfd)
        let updated = try local.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: 0)
        #expect(updated.title == nfc)
        #expect(updated.topic == nfc)
        let resolved = try local.resolveSessionByTitle(nfd, lifecycleState: ConversationLifecycleState.active.rawValue)
        #expect(resolved == cid)
    }
}
