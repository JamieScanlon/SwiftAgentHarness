import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Catalog schema v14 resource columns")
struct SessionCatalogSchemaV14Tests {

    @Test func freshStoreOpensAtSchemaV14() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-v14-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        #expect(try local.catalogSchemaVersion() == SQLiteSessionCatalog.kSupportedCatalogSchemaVersion)
        #expect(try local.catalogSchemaVersion() == 18)
    }

    @Test func transcriptIntegrityRoundTripsThroughCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-v15-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )
        try local.quarantineTranscript(conversationID: cid, reason: "test damage")
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity?.state == .quarantined)
        #expect(try local.catalogConversation(id: cid)?.transcriptIntegrity?.reason == "test damage")
    }

    @Test func resourcePatchRoundTripsThroughCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-v14-patch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )

        let resourceJSON = """
        {"extraInstructions":"be concise","tags":["a"],"systemPrompt":"sys"}
        """
        var patch = SessionConversationUpdatePatch()
        patch.resourceJSON = .set(resourceJSON)
        patch.currentRunID = .set(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        patch.lastActiveAt = .set(Date(timeIntervalSince1970: 1_700_000_000))
        patch.resourceRunStatusRaw = .set(ConversationResourceRunStatus.running.rawValue)
        patch.systemPrompt = .set("sys")
        let updated = try local.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: nil)
        #expect(updated.resourceJSON == resourceJSON)
        #expect(updated.currentRunID?.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(updated.resourceRunStatusRaw == ConversationResourceRunStatus.running.rawValue)
        #expect(updated.systemPrompt == "sys")
        #expect(updated.controlPlaneRevision == 1)
    }

    @Test func expectedRevisionCASUsesControlPlaneRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-v14-cas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        try local.bootstrapEmptyConversation(
            SessionCatalogRecord(
                id: cid,
                topic: "T",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue
            )
        )

        var patch = SessionConversationUpdatePatch()
        patch.title = .set("T2")
        _ = try local.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: 0)
        #expect(try local.catalogConversation(id: cid)?.controlPlaneRevision == 1)

        patch.title = .set("T3")
        #expect(throws: SessionPersistenceError.self) {
            _ = try local.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: 0)
        }
        _ = try local.updateSessionConversation(conversationID: cid, patch: patch, expectedRevision: 1)
        #expect(try local.catalogConversation(id: cid)?.title == "T3")
        #expect(try local.catalogConversation(id: cid)?.controlPlaneRevision == 2)
    }
}
