import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence Gap 12 (lite-read recovery)")
struct SessionPersistenceGap12Tests {
    @Test func recoveryIndexDecodeReturnsSortedIds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let u1 = UUID()
        let u2 = UUID()
        try SessionPersistenceLayout.ensureDirectory(root)
        try SessionPersistenceRecoveryIndexWriter.writeSessionsRecoveryIndex(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId,
            authProfileLabel: nil,
            catalogSchemaVersion: 1,
            conversationIds: [u1, u2]
        )

        let found = SessionPersistenceLiteRecovery.discoverConversationIds(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId
        )
        #expect(Set(found) == Set([u1, u2]))
    }

    @Test func jsonlWithoutSessionsJsonFindsBasenameAndHeader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-jsonl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        _ = try LocalHarnessSessionPersistence(root: root, agentId: agentId)

        let cid = UUID()
        let url = SessionPersistenceLayout.transcriptURL(root: root, agentId: agentId, conversationId: cid)
        let writer = SessionJSONLTranscriptWriter(fileURL: url)
        try writer.writeFreshHeader(conversationId: cid)

        let sessionsURL = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
        try? FileManager.default.removeItem(at: sessionsURL)

        let found = SessionRecoveryDiscoveryService.discoverRecoverableConversationIds(root: root, agentId: agentId)
        #expect(found.contains(cid))
    }

    @Test func afterCatalogDeletionLiteDiscoveryStillFindsJsonlConversations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-catdel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentId = SessionPersistenceLayout.defaultAgentId
        let local = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        let u1 = UUID()
        let u2 = UUID()
        for cid in [u1, u2] {
            var row = SessionCatalogRecord(
                id: cid,
                topic: "g12-\(cid.uuidString)",
                description: nil,
                messageCount: 0,
                updatedAt: Date(),
                createdAt: Date(),
                modelName: "m",
                interactionModeRaw: InteractionMode.chat.rawValue,
            )
            row.agentId = agentId
            try local.bootstrapEmptyConversation(row)
        }

        for name in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: false))
        }

        let reopened = try LocalHarnessSessionPersistence(root: root, agentId: agentId)
        #expect(try reopened.listCatalogConversations().isEmpty)

        let recovered = SessionRecoveryDiscoveryService.discoverRecoverableConversationIds(root: root, agentId: agentId)
        #expect(Set(recovered).isSuperset(of: [u1, u2]))
    }

    @Test func damagedSessionsJsonHeadTailScanFindsUuids() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-dmg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try HarnessEnvironmentOverride.$overrides.withValue(["SAH_SESSION_LITE_RECOVERY_SCAN_BYTES": "2048"]) {
            let ua = UUID()
            let ub = UUID()
            let prefix = "not-json {\n \"hint\": \"\(ua.uuidString)\"\n"
            let middle = String(repeating: "Z", count: 80_000)
            let suffix = "\n\"tail\": \"\(ub.uuidString)\"\n"
            var blob = Data(prefix.utf8)
            blob.append(contentsOf: middle.utf8)
            blob.append(contentsOf: suffix.utf8)

            try SessionPersistenceLayout.ensureDirectory(root)
            let url = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
            try SessionPersistenceLayout.ensureDirectory(url.deletingLastPathComponent())
            try blob.write(to: url)

            let found = SessionPersistenceLiteRecovery.discoverConversationIds(
                root: root,
                agentId: SessionPersistenceLayout.defaultAgentId
            )
            #expect(found.contains(ua))
            #expect(found.contains(ub))
        }
    }

    @Test func recoveryDiscoveryServiceReadsRecoveryIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-router-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let u = UUID()
        try SessionPersistenceLayout.ensureDirectory(root)
        try SessionPersistenceRecoveryIndexWriter.writeSessionsRecoveryIndex(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId,
            authProfileLabel: nil,
            catalogSchemaVersion: 0,
            conversationIds: [u]
        )

        let ids = SessionRecoveryDiscoveryService.discoverRecoverableConversationIds(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId
        )
        #expect(ids.contains(u))
    }

    @Test func recoveryDiscoveryServiceReturnsEmptyWhenNothingIndexed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap12-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try SessionPersistenceLayout.ensureDirectory(root)
        let ids = SessionRecoveryDiscoveryService.discoverRecoverableConversationIds(
            root: root,
            agentId: SessionPersistenceLayout.defaultAgentId
        )
        #expect(ids.isEmpty)
    }
}
