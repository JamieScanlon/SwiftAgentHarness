import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment representation materializer")
struct AttachmentRepresentationMaterializerTests {
    private func makeBlobReader(harness: InMemoryHarnessSessionPersistence, conversationID: UUID) -> AttachmentBlobReading {
        AttachmentBlobReading.harness(harness, conversationID: conversationID)
    }

    private func storeTextBlob(
        harness: InMemoryHarnessSessionPersistence,
        text: String
    ) throws -> String {
        let ref = try harness.putBlob(
            data: Data(text.utf8),
            durability: .durable,
            originalName: "sample.txt",
            mimeType: "text/plain",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        return ref.id
    }

    @Test("Text digest includes excerpt, elision marker, byte count, and recovery instruction")
    func textDigestIncludesBoundedPreviewAndRecovery() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let body = String(repeating: "abcdefghij", count: 500)
        let blobId = try storeTextBlob(harness: harness, text: body)
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            blobId: blobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: Int64(body.utf8.count),
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let decision = ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: .summarize,
            reason: "within_summary_budget"
        )
        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [decision],
            catalog: [descriptor],
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID,
            configuration: AttachmentRepresentationMaterializerConfiguration(digestHeadMaxBytes: 64, digestTailMaxBytes: 32)
        )
        let block = try #require(blocks.first)
        #expect(block.body.contains("[attachment digest]"))
        #expect(block.body.contains("preview:"))
        #expect(block.body.contains("abcdefghij"))
        #expect(block.body.contains("original_byte_count: \(body.utf8.count)"))
        #expect(block.body.contains("bytes elided"))
        #expect(block.body.contains("attachment_id: \(descriptor.id.uuidString)"))
        #expect(block.body.contains("blob_id: \(blobId)"))
        #expect(block.body.contains("Use read_attachment with attachment_id \(descriptor.id.uuidString)"))
        #expect(!block.body.contains("read_file"))
        #expect(!block.body.contains("read_path:"))
    }

    @Test("Reference disposition emits metadata line and recovery instruction")
    func referenceDispositionIncludesMetadataAndRecovery() throws {
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "document",
            name: "generated.pdf",
            mimeType: "application/pdf",
            byteSize: 4_000_000,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let decision = ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: .searchOnly,
            reason: "low_trust"
        )
        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [decision],
            catalog: [descriptor],
            modelSupportsVision: false,
            blobReader: nil,
            conversationID: UUID()
        )
        let block = try #require(blocks.first)
        #expect(block.body.contains("[attachment reference]"))
        #expect(block.body.contains("name: generated.pdf"))
        #expect(block.body.contains("kind: document"))
        #expect(block.body.contains("mime_type: application/pdf"))
        #expect(block.body.contains("byte_size: 4000000"))
        #expect(block.body.contains("attachment_id: \(descriptor.id.uuidString)"))
        #expect(block.body.contains("Use read_attachment with attachment_id \(descriptor.id.uuidString)"))
        #expect(!block.body.contains("read_file"))
    }

    @Test("Vision-unsupported image digest is an honest capability marker")
    func visionUnsupportedImageUsesHonestMarker() throws {
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "image",
            name: "diagram.png",
            mimeType: "image/png",
            byteSize: 10_000,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let decision = ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: .summarize,
            reason: "vision_unsupported"
        )
        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [decision],
            catalog: [descriptor],
            modelSupportsVision: false,
            blobReader: nil,
            conversationID: UUID()
        )
        let block = try #require(blocks.first)
        #expect(block.body.contains("image attached; active model cannot view images"))
        #expect(!block.body.contains("preview:"))
    }

    @Test("Low-trust digest is envelope-wrapped")
    func lowTrustDigestIsEnvelopeWrapped() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobId = try storeTextBlob(harness: harness, text: "hostile body")
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            blobId: blobId,
            kind: "document",
            name: "scripted.txt",
            mimeType: "text/plain",
            byteSize: 12,
            trustRaw: AttachmentInputTrust.scripted.rawValue
        )
        let decision = ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: .summarize,
            reason: "within_summary_budget"
        )
        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [decision],
            catalog: [descriptor],
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: conversationID),
            conversationID: conversationID
        )
        let block = try #require(blocks.first)
        #expect(ExternalContentEnvelope.isAlreadyWrapped(block.body))
        #expect(block.body.contains("SECURITY NOTICE"))
    }

    @Test("Missing blob emits unavailable marker with attachment id")
    func missingBlobEmitsUnavailableMarker() throws {
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            blobId: "abc123",
            kind: "document",
            name: "missing.txt",
            mimeType: "text/plain",
            byteSize: 100,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let decision = ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: .summarize,
            reason: "within_summary_budget"
        )
        let harness = InMemoryHarnessSessionPersistence()
        let blocks = AttachmentRepresentationMaterializer.materialize(
            decisions: [decision],
            catalog: [descriptor],
            modelSupportsVision: true,
            blobReader: makeBlobReader(harness: harness, conversationID: UUID()),
            conversationID: UUID()
        )
        let block = try #require(blocks.first)
        #expect(block.body.contains("[attachment unavailable: missing.txt]"))
        #expect(block.body.contains("attachment_id: \(descriptor.id.uuidString)"))
    }

    @Test("AttachmentProjectionDispatchCodec detects materialized blocks")
    func dispatchCodecDetectsMaterializedBlocks() {
        let payload: JSON = .object([
            "contextEngineAttachmentProjection": .object([
                "projectionFingerprint": .string("fp"),
                "decisions": .array([]),
                "materializedBlocks": .array([
                    .object([
                        "attachmentID": .string(UUID().uuidString),
                        "attachmentName": .string("a.txt"),
                        "disposition": .string("summarize"),
                        "body": .string("digest body"),
                    ]),
                ]),
            ]),
        ])
        #expect(AttachmentProjectionDispatchCodec.hasMaterializedBlocks(in: payload))
        #expect(!AttachmentProjectionDispatchCodec.hasMaterializedBlocks(in: .object([:])))
    }
}
