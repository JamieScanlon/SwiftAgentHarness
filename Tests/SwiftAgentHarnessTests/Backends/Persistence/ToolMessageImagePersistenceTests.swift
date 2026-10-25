import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool message images in persistence")
struct ToolMessageImagePersistenceTests {
    private func persistence() throws -> LocalHarnessSessionPersistence {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-image-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try LocalHarnessSessionPersistence(root: root, agentId: "test-agent")
    }

    private func toolMessage(images: [Message.Image]) -> Message {
        Message(id: UUID(), role: .tool, content: "observed", images: images, toolCallId: "call-1")
    }

    @Test("Inline tool images are stored as blobs; the message keeps its bytes and gains a blob ref")
    func offloadsInlineImages() throws {
        let harness = try persistence()
        let message = toolMessage(images: [
            Message.Image(name: "call-1-image-1", imageData: ToolImageFixtures.tinyPNG, mediaType: "image/png"),
        ])
        let offloaded = ToolMessageImageOffload.offload(message, harness: harness)
        let image = try #require(offloaded.images.first)
        let blobID = try #require(SessionBlobImageRef.parsePath(image.path))
        #expect(image.imageData == ToolImageFixtures.tinyPNG)
        #expect(image.mediaType == "image/png")
        #expect(try harness.getBlob(blobId: blobID) == ToolImageFixtures.tinyPNG)
    }

    @Test("Images already on a blob ref, and images without bytes, are left alone")
    func leavesRefsAlone() throws {
        let harness = try persistence()
        let message = toolMessage(images: [
            Message.Image(name: "a", path: SessionBlobImageRef.path(for: String(repeating: "a", count: 64)), imageData: ToolImageFixtures.tinyPNG),
            Message.Image(name: "b", path: "https://example.com/x.png"),
        ])
        let offloaded = ToolMessageImageOffload.offload(message, harness: harness)
        #expect(offloaded.images.map(\.path) == message.images.map(\.path))
    }

    @Test("Tool images in a conversation with user attachments survive vision projection; without vision they are dropped")
    func projectorLeavesToolImagesToFormatting() {
        let attachment = ConversationAttachmentDescriptor(
            id: UUID(), blobId: String(repeating: "b", count: 64), kind: "image", name: "photo.jpg",
            mimeType: "image/jpeg", byteSize: 10
        )
        let tool = toolMessage(images: [Message.Image(name: "call-1-image-1", imageData: ToolImageFixtures.tinyPNG, mediaType: "image/png")])
        for (vision, expected) in [(true, 1), (false, 0)] {
            let projected = CatalogVisionImageProjector.apply(
                messages: [tool],
                catalog: [attachment],
                effectiveDecisions: [],
                blobReader: nil,
                conversationID: UUID(),
                modelSupportsVision: vision
            )
            #expect(projected.first?.images.count == expected)
            #expect(projected.first?.content == "observed")
        }
    }

    @Test("The transcript keeps a tool image's blob ref and media type, and hydration restores its bytes")
    func transcriptRoundTrip() throws {
        let harness = try persistence()
        let offloaded = ToolMessageImageOffload.offload(
            toolMessage(images: [Message.Image(name: "call-1-image-1", imageData: ToolImageFixtures.tinyPNG, mediaType: "image/png")]),
            harness: harness
        )
        let json = try MessageTranscriptPayloadCodec.encodePayloadJSON(from: offloaded)
        let decoded = try MessageTranscriptPayloadCodec.decode(json).asMessage()
        #expect(decoded.role == .tool)
        #expect(decoded.images.first?.mediaType == "image/png")
        #expect(decoded.images.first?.imageData == nil)
        let hydrated = SessionBlobMessageHydration.hydrateBlobImages(in: decoded, harness: harness)
        #expect(hydrated.images.first?.imageData == ToolImageFixtures.tinyPNG)
    }
}
