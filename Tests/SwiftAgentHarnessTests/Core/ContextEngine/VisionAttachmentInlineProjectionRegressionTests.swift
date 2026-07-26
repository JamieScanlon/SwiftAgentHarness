import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// End-to-end: natural decision + projector for a ~1.3MB vision upload.
@Suite("Vision attachment over text inlineByteLimit projection")
struct VisionAttachmentInlineProjectionRegressionTests {
    @Test("~1.3MB user image on vision model keeps projected imageData")
    func oversizedPhotoKeepsProjectedImageData() throws {
        let policy = ContextEngineAttachmentProjectionPolicyInput()
        #expect(policy.inlineByteLimit == 256_000)
        #expect(policy.imageInlineByteLimit == 5_000_000)

        let original = Data(repeating: 0x7E, count: 1_370_000)
        let sanitized = Data(repeating: 0x42, count: 180_000)
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
        let attachment = ConversationAttachmentDescriptor(
            id: UUID(),
            blobId: blobRef.id,
            kind: "image",
            name: "photo.jpg",
            mimeType: "image/jpeg",
            byteSize: Int64(original.count)
        )
        let natural = AttachmentRecencyProjectionPolicy.naturalDecision(
            for: attachment,
            modelSupportsVision: true,
            policy: policy
        )
        #expect(natural.disposition == .inline)
        #expect(natural.reason == "within_image_inline_budget")

        let message = Message(
            id: UUID(),
            role: .user,
            content: "what is in this photo?",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        let projected = CatalogVisionImageProjector.apply(
            messages: [message],
            catalog: [attachment],
            effectiveDecisions: [natural],
            blobReader: AttachmentBlobReading.harness(harness, conversationID: conversationID),
            conversationID: conversationID,
            modelSupportsVision: true,
            sanitizationPolicy: .init(from: policy),
            imageProcessor: RegressionMockImageProcessor(sanitized: sanitized)
        )
        #expect(projected[0].images.count == 1)
        let imageData = try #require(projected[0].images[0].imageData)
        #expect(imageData == sanitized)
        #expect(imageData.count <= policy.imageInlineByteLimit)
        #expect(imageData.count > 0)
    }
}

private struct RegressionMockImageProcessor: ImageProcessing {
    let sanitized: Data

    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { sanitized }
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? { sanitized }
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        sanitized.count <= maxFileSize ? sanitized : nil
    }
}
