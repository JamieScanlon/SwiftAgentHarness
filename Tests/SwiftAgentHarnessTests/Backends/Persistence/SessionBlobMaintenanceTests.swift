import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Session blob install maintenance")
struct SessionBlobMaintenanceTests {
    @Test func liveSetSpansAllAgentsOnSharedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-cross-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentA = try LocalHarnessSessionPersistence(root: root, agentId: "agent-a")
        let agentB = try LocalHarnessSessionPersistence(root: root, agentId: "agent-b")

        let data = Data("shared-bytes".utf8)
        let blobRef = try agentA.putBlob(
            data: data,
            durability: .durable,
            originalName: "shared.txt",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )

        func append(to local: LocalHarnessSessionPersistence, cid: UUID) throws {
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
                content: "see",
                timestamp: Date(),
                images: [Message.Image(name: "shared.txt", path: SessionBlobImageRef.path(for: blobRef.id))],
                toolCalls: []
            )
            let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
            try local.appendTranscriptEntry(conversationID: cid, entry: entry)
        }

        try append(to: agentA, cid: UUID())
        try append(to: agentB, cid: UUID())

        let live = try SessionBlobReferenceScanner.allReferencedDurableBlobIds(root: root)
        #expect(live.contains(blobRef.id))
    }

    @Test func reclaimRetainsReferencedBlob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-sweep-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)

        let blobRef = try local.putBlob(
            data: Data("keep".utf8),
            durability: .durable,
            originalName: "keep.txt",
            mimeType: "text/plain",
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
            content: "x",
            timestamp: Date(),
            images: [Message.Image(name: "keep.txt", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        try local.appendTranscriptEntry(
            conversationID: cid,
            entry: try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        )

        let live = try SessionBlobReferenceScanner.allReferencedDurableBlobIds(root: root)
        let store = SessionBlobStore(root: root, maxBytes: 1_048_576)
        let counts = try store.reclaimUnreferencedDurable(liveBlobIds: live, trashRetentionInterval: 0)
        #expect(counts.trashed == 0)
        #expect(counts.hardDeleted == 0)
        #expect(try local.getBlob(blobId: blobRef.id) == Data("keep".utf8))
    }

    @Test func reclaimHardDeletesUnreferencedAfterRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-sweep-free-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)

        let blobRef = try local.putBlob(
            data: Data("orphan".utf8),
            durability: .durable,
            originalName: "orphan.txt",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let store = SessionBlobStore(root: root, maxBytes: 1_048_576)
        let counts = try store.reclaimUnreferencedDurable(liveBlobIds: [], trashRetentionInterval: 0)
        #expect(counts.trashed == 1)
        #expect(counts.hardDeleted == 1)
        #expect(throws: SessionPersistenceError.self) {
            try local.getBlob(blobId: blobRef.id)
        }
    }

    @Test func markThenPutRaceDoesNotDangle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let data = Data("race-bytes".utf8)
        let blobRef = try local.putBlob(
            data: data,
            durability: .durable,
            originalName: "race.txt",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound,
        )
        let store = SessionBlobStore(root: root, maxBytes: 1_048_576)
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [])
        _ = try local.putBlob(
            data: data,
            durability: .durable,
            originalName: "race2.txt",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let dangling = try SessionBlobReferenceScanner.danglingDurableBlobReferences(root: root)
        #expect(dangling.isEmpty)
        #expect(try local.getBlob(blobId: blobRef.id) == data)
    }

    @Test func trashedReferencedBlobIsNotDangling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-trash-dangling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let blobRef = try local.putBlob(
            data: Data("trashed-ref".utf8),
            durability: .durable,
            originalName: "ref.txt",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
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
            content: "see",
            timestamp: Date(),
            images: [Message.Image(name: "ref.txt", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        try local.appendTranscriptEntry(
            conversationID: cid,
            entry: try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        )
        let store = SessionBlobStore(root: root, maxBytes: 1_048_576)
        _ = try store.markUnreferencedDurableForTrash(liveBlobIds: [])
        let trashURL = SessionPersistenceLayout.durableTrashFileURL(root: root, blobId: blobRef.id)
        #expect(FileManager.default.fileExists(atPath: trashURL.path))
        #expect(SessionBlobStore.durableFileExists(root: root, blobId: blobRef.id))

        let dangling = try SessionBlobReferenceScanner.danglingDurableBlobReferences(root: root)
        #expect(dangling.isEmpty)
    }

    @Test func integrityReportElevatedWhenLocalizedDangling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blob-report-elevated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        let healthyRef = try local.putBlob(
            data: Data([0x02]),
            durability: .durable,
            originalName: "ok.bin",
            mimeType: nil,
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let missingRef = try local.putBlob(
            data: Data([0x01]),
            durability: .durable,
            originalName: "a.bin",
            mimeType: nil,
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
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
        for (sequence, blobId, name) in [(1, healthyRef.id, "ok.bin"), (2, missingRef.id, "a.bin")] {
            let message = Message(
                id: UUID(),
                role: .user,
                content: "x",
                timestamp: Date(),
                images: [Message.Image(name: name, path: SessionBlobImageRef.path(for: blobId))],
                toolCalls: []
            )
            try local.appendTranscriptEntry(
                conversationID: cid,
                entry: try SessionTranscriptMapping.entry(from: message, sequence: sequence, parentEntryId: nil)
            )
        }
        try local.deleteBlob(blobId: missingRef.id)

        let report = try SessionBlobReferenceScanner.integrityReport(
            root: root,
            graceSeconds: 3600,
            reclaimUnreferenced: false
        )
        #expect(report.referencedCount == 2)
        #expect(report.danglingCount == 1)
        #expect(report.severity == .elevated)
    }
}
