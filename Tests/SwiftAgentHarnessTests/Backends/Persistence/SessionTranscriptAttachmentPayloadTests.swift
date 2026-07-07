import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Session transcript attachment payload v3")
struct SessionTranscriptAttachmentPayloadTests {
    @Test func attachmentRefsRoundTripThroughAppendAndReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

        let blobRef = try local.putBlob(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            durability: .durable,
            originalName: "shot.png",
            mimeType: "image/png",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see image",
            timestamp: Date(),
            images: [Message.Image(name: "shot.png", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: [],
            toolCallId: nil,
            responseFormat: nil,
            inputTrustRaw: "user-direct"
        )
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        try local.appendTranscriptEntry(conversationID: cid, entry: entry)

        let payload = try MessageTranscriptPayloadCodec.decode(entry.payloadJSON)
        #expect(payload.v == 4)
        #expect(payload.attachmentRefs?.count == 1)
        #expect(payload.attachmentRefs?.first?.blobId == blobRef.id)

        let rows = try local.readTranscriptEntries(conversationID: cid, request: .full)
        let replayed = try #require(try SessionTranscriptMapping.messageForReplay(from: rows[0]))
        #expect(replayed.images.count == 1)
        #expect(replayed.images[0].path == SessionBlobImageRef.path(for: blobRef.id))
    }

    @Test func v2PayloadWithoutRefsStillDecodes() throws {
        let thin = """
        {"v":2,"id":"550e8400-e29b-41d4-a716-446655440000","role":"user","content":"hi","timestamp":0,"toolCalls":[{"id":"tc-1","name":"search","argumentsJson":"{}"}]}
        """
        let entry = SessionTranscriptEntry(
            sequence: 1,
            entryId: SessionEntryID.fromMessageUUID(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!),
            parentEntryId: nil,
            type: .message,
            timestamp: Date(timeIntervalSince1970: 0),
            payloadJSON: thin
        )
        let replayed = try #require(try SessionTranscriptMapping.messageForReplay(from: entry))
        #expect(replayed.images.isEmpty)
        #expect(replayed.toolCalls.count == 1)
    }

    @Test func transcriptOnlyReplayHydratesBlobBytesWithoutSwiftData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let data = Data("pixels".utf8)
        let blobRef = try local.putBlob(
            data: data,
            durability: .durable,
            originalName: "a.png",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let message = Message(
            id: UUID(),
            role: .user,
            content: "pic",
            timestamp: Date(),
            images: [Message.Image(name: "a.png", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        let replayed = try #require(try SessionTranscriptMapping.messageForReplay(from: entry))
        let hydrated = SessionBlobMessageHydration.hydrateBlobImages(in: [replayed], harness: local)
        #expect(hydrated[0].images.first?.imageData == data)
    }

    @Test func hydrationSubstitutesPlaceholderWhenBlobMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        let blobRef = try local.putBlob(
            data: Data("gone".utf8),
            durability: .durable,
            originalName: "gone.png",
            mimeType: "text/plain",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let message = Message(
            id: UUID(),
            role: .user,
            content: "pic",
            timestamp: Date(),
            images: [Message.Image(name: "gone.png", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        try local.deleteBlob(blobId: blobRef.id)
        let entry = try SessionTranscriptMapping.entry(from: message, sequence: 1, parentEntryId: nil)
        let replayed = try #require(try SessionTranscriptMapping.messageForReplay(from: entry))
        let hydrated = SessionBlobMessageHydration.hydrateBlobImages(in: [replayed], harness: local)
        #expect(hydrated[0].images.isEmpty)
        #expect(hydrated[0].content.contains(SessionBlobMessageHydration.unavailableMarker(name: "gone.png")))
    }
}
