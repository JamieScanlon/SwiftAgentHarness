import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment ingest service")
struct AttachmentIngestServiceTests {
    private func makeStack(label: String) throws -> (ConversationPersistenceStack, URL) {
        let (stack, _, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
        return (stack, root)
    }

    @Test("ingest puts bytes into durable blob and merges catalog")
    func ingestFromImageData() throws {
        let (stack, root) = try makeStack(label: "ingest-bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let data = Data("pixels".utf8)
        let image = Message.Image(name: "shot.png", imageData: data, thumbData: data)
        let result = try AttachmentIngestService.ingestImages(
            conversationID: conversation.id,
            images: [image],
            harness: stack.harnessSessionPersistence,
            conversationManager: stack.conversationManager,
            attachmentTrustRaw: AttachmentInputTrust.directUserEntry.rawValue,
            addedBy: .user
        )
        #expect(result.refOnlyImages.count == 1)
        #expect(result.refOnlyImages[0].imageData == nil)
        #expect(SessionBlobImageRef.parsePath(result.refOnlyImages[0].path) != nil)
        #expect(result.ingestRefs.count == 1)
        let reloaded = try #require(stack.conversationManager.modelConversation(id: conversation.id))
        #expect(reloaded.attachmentsCatalog.count == 1)
        #expect(reloaded.attachmentsCatalog[0].id == result.ingestRefs[0].attachmentId)
        #expect(reloaded.attachmentsCatalog[0].blobId == result.ingestRefs[0].blobId)
    }

    @Test("re-ingest same blob id reuses catalog attachment id")
    func idempotentReIngest() throws {
        let (stack, root) = try makeStack(label: "ingest-idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let blobRef = try stack.harnessSessionPersistence.putBlob(
            data: Data("same".utf8),
            durability: .durable,
            originalName: "a.png",
            mimeType: "image/png",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let path = SessionBlobImageRef.path(for: blobRef.id)
        let first = try AttachmentIngestService.ingestImages(
            conversationID: conversation.id,
            images: [Message.Image(name: "a.png", path: path)],
            harness: stack.harnessSessionPersistence,
            conversationManager: stack.conversationManager,
            attachmentTrustRaw: nil,
            addedBy: .user
        )
        let second = try AttachmentIngestService.ingestImages(
            conversationID: conversation.id,
            images: [Message.Image(name: "a.png", path: path)],
            harness: stack.harnessSessionPersistence,
            conversationManager: stack.conversationManager,
            attachmentTrustRaw: nil,
            addedBy: .user
        )
        #expect(first.ingestRefs[0].attachmentId == second.ingestRefs[0].attachmentId)
        let reloaded = try #require(stack.conversationManager.modelConversation(id: conversation.id))
        #expect(reloaded.attachmentsCatalog.count == 1)
    }

    @Test("ephemeral blob is promoted to durable on ingest")
    func promotesEphemeralBlob() throws {
        let (stack, root) = try makeStack(label: "ingest-promote")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let blobRef = try stack.harnessSessionPersistence.putBlob(
            data: Data("tmp".utf8),
            durability: .ephemeral,
            originalName: "tmp.png",
            mimeType: "image/png",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: 3_600,
            lane: .inbound
        )
        let path = SessionBlobImageRef.path(for: blobRef.id)
        _ = try AttachmentIngestService.ingestImages(
            conversationID: conversation.id,
            images: [Message.Image(name: "tmp.png", path: path)],
            harness: stack.harnessSessionPersistence,
            conversationManager: stack.conversationManager,
            attachmentTrustRaw: nil,
            addedBy: .user
        )
        let stat = try stack.harnessSessionPersistence.statBlob(blobId: blobRef.id)
        #expect(stat.durability == .durable)
    }

    @Test("save message persists catalog and attachment id on transcript refs")
    func saveMessageMergesCatalog() throws {
        let (stack, root) = try makeStack(label: "ingest-save")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let data = Data("save-path".utf8)
        let message = Message(
            id: UUID(),
            role: .user,
            content: "image please",
            timestamp: Date(),
            images: [Message.Image(name: "save.png", imageData: data, thumbData: data)],
            toolCalls: [],
            inputTrustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        _ = try stack.saveMessage(
            message,
            for: conversation.id,
            resourceManager: nil,
            logger: nil
        )
        let reloaded = try #require(stack.conversationManager.modelConversation(id: conversation.id))
        #expect(reloaded.attachmentsCatalog.count == 1)
        let rows = try stack.harnessSessionPersistence.readTranscriptEntries(conversationID: conversation.id, request: .full)
        let payload = try rows
            .map { try MessageTranscriptPayloadCodec.decode($0.payloadJSON) }
            .first { $0.id == message.id }
        let decoded = try #require(payload)
        #expect(decoded.attachmentRefs?.count == 1)
        #expect(decoded.attachmentRefs?.first?.attachmentId == reloaded.attachmentsCatalog[0].id)
    }
}

@Suite("Catalog vision image projector")
struct CatalogVisionImageProjectorTests {
    private func descriptor(
        id: UUID = UUID(),
        name: String = "shot.png",
        blobId: String,
        byteSize: Int64 = 6
    ) -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: id,
            blobId: blobId,
            kind: "image",
            name: name,
            mimeType: "image/png",
            byteSize: byteSize
        )
    }

    private func decision(
        for descriptor: ConversationAttachmentDescriptor,
        disposition: ConversationAttachmentProjectionDisposition
    ) -> ConversationAttachmentProjectionDecision {
        ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: disposition,
            reason: "test"
        )
    }

    @Test("inline vision images are hydrated on the projection copy")
    func inlineHydratesProjectionCopy() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobRef = try harness.putBlob(
            data: Data("pixels".utf8),
            durability: .durable,
            originalName: "shot.png",
            mimeType: "image/png",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let attachment = descriptor(blobId: blobRef.id)
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see image",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let blobReader = AttachmentBlobReading.harness(harness, conversationID: conversationID)
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [decision(for: attachment, disposition: .inline)],
            blobReader: blobReader,
            conversationID: conversationID,
            modelSupportsVision: true
        )
        #expect(projected[0].images.count == 1)
        #expect(projected[0].images[0].imageData == Data("pixels".utf8))
        #expect(message.images[0].imageData == nil)
    }

    @Test("summarized images are stripped from projected messages")
    func nonInlineStripsImages() {
        let attachment = descriptor(blobId: String(repeating: "a", count: 64))
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see image",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: attachment.blobId!))],
            toolCalls: []
        )
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [decision(for: attachment, disposition: .summarize)],
            blobReader: nil,
            conversationID: UUID(),
            modelSupportsVision: true
        )
        #expect(projected[0].images.isEmpty)
    }

    @Test("inline images are stripped when model does not support vision")
    func nonVisionStripsInlineImages() {
        let attachment = descriptor(blobId: String(repeating: "b", count: 64))
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see image",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: attachment.blobId!))],
            toolCalls: []
        )
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [decision(for: attachment, disposition: .inline)],
            blobReader: nil,
            conversationID: UUID(),
            modelSupportsVision: false
        )
        #expect(projected[0].images.isEmpty)
    }

    @Test("oversized vision blob stays on projected message as sanitized imageData")
    func oversizedVisionBlobKeepsSanitizedImageData() throws {
        let original = Data(repeating: 0xAB, count: 1_370_000)
        let sanitized = Data("sanitized-pixels".utf8)
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobRef = try harness.putBlob(
            data: original,
            durability: .durable,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let attachment = descriptor(
            name: "photo.jpg",
            blobId: blobRef.id,
            byteSize: Int64(original.count)
        )
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see photo",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let processor = VisionProjectorMockImageProcessor(
            scaleResult: sanitized,
            scaleToFileSizeResult: sanitized
        )
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [decision(for: attachment, disposition: .inline)],
            blobReader: AttachmentBlobReading.harness(harness, conversationID: conversationID),
            conversationID: conversationID,
            modelSupportsVision: true,
            sanitizationPolicy: .init(maxPixelDimension: 1_200, maxBytes: 256_000),
            imageProcessor: processor
        )
        #expect(projected[0].images.count == 1)
        #expect(projected[0].images[0].imageData == sanitized)
        #expect(projected[0].images[0].imageData?.count ?? 0 <= 256_000)
    }

    @Test("sanitize failure omits image from projection")
    func sanitizeFailureOmitsImage() throws {
        let original = Data(repeating: 0xCD, count: 400_000)
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobRef = try harness.putBlob(
            data: original,
            durability: .durable,
            originalName: "bad.jpg",
            mimeType: "image/jpeg",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let attachment = descriptor(name: "bad.jpg", blobId: blobRef.id, byteSize: Int64(original.count))
        let message = Message(
            id: UUID(),
            role: .user,
            content: "see photo",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [decision(for: attachment, disposition: .inline)],
            blobReader: AttachmentBlobReading.harness(harness, conversationID: conversationID),
            conversationID: conversationID,
            modelSupportsVision: true,
            sanitizationPolicy: .init(maxPixelDimension: 1_200, maxBytes: 256_000),
            imageProcessor: VisionProjectorMockImageProcessor(
                scaleResult: .some(nil),
                scaleToFileSizeResult: nil
            )
        )
        #expect(projected[0].images.isEmpty)
    }
}

private struct VisionProjectorMockImageProcessor: ImageProcessing {
    var scaleResult: Data??
    var scaleToFileSizeResult: Data?

    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { data }

    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? {
        if let explicit = scaleResult {
            return explicit
        }
        return data
    }

    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        if let explicit = scaleToFileSizeResult { return explicit }
        return data.count <= maxFileSize ? data : nil
    }
}
