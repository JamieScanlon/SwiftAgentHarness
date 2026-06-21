import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Session blob hard delete")
struct SessionBlobDeleteTests {
    @Test func hardDeleteSucceedsWhileCatalogStillReferencesBlob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-purge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)

        let blobRef = try local.putBlob(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            durability: .durable,
            originalName: "a.png",
            mimeType: "image/png",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )

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
        let message = Message(
            id: UUID(),
            role: .user,
            content: "img",
            timestamp: Date(),
            images: [Message.Image(name: "a.png", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: entry)

        try local.deleteBlob(blobId: blobRef.id)
        #expect(throws: SessionPersistenceError.self) {
            try local.getBlob(blobId: blobRef.id)
        }

        let dangling = try SessionBlobReferenceScanner.danglingDurableBlobReferences(root: root)
        #expect(dangling.contains { $0.blobId == blobRef.id && $0.conversationID == cid })
    }

    @Test func openReferencedDurableBlobThrowsDurableBlobMissingWhenBytesGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()

        let blobRef = try local.putBlob(
            data: Data([0x01, 0x02]),
            durability: .durable,
            originalName: "x.bin",
            mimeType: nil,
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        try local.deleteBlob(blobId: blobRef.id)

        do {
            _ = try local.openReferencedDurableBlob(blobId: blobRef.id, conversationID: cid)
            Issue.record("expected durableBlobMissing")
        } catch SessionPersistenceError.durableBlobMissing(let id, let conversationID) {
            #expect(id == blobRef.id)
            #expect(conversationID == cid)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
