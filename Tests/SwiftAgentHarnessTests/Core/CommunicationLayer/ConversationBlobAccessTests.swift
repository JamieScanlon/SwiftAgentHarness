import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Conversation blobs: only what the conversation references")
struct ConversationBlobAccessTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func model() -> Model {
        Model(protocol: .ollama, modelName: "test:latest", serverURL: URL(string: "http://localhost:11434")!, capabilities: [], modelProtocol: .ollama)
    }

    private func put(_ data: Data, into local: LocalHarnessSessionPersistence) throws -> String {
        try local.putBlob(
            data: data,
            durability: .durable,
            originalName: "shot.png",
            mimeType: "image/png",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        ).id
    }

    @Test("Ids and blob refs normalize; anything else is not a blob id")
    func normalizing() {
        let id = String(repeating: "A", count: 64)
        #expect(ConversationBlobAccess.normalizedID(id) == id.lowercased())
        #expect(ConversationBlobAccess.normalizedID("blob://\(id)") == id.lowercased())
        #expect(ConversationBlobAccess.normalizedID("../../etc/passwd") == nil)
    }

    @Test("Attachments and message images count as references; other blobs don't")
    func references() {
        let attached = String(repeating: "a", count: 64)
        let pictured = String(repeating: "b", count: 64)
        let attachment = ConversationAttachmentDescriptor(id: UUID(), blobId: attached.uppercased(), kind: "image", name: "a.png")
        let message = Message(
            id: UUID(), role: .user, content: "look", timestamp: Date(),
            images: [Message.Image(name: "b.png", path: SessionBlobImageRef.path(for: pictured))], toolCalls: []
        )
        #expect(ConversationBlobAccess.references(attached, attachments: [attachment], messages: []))
        #expect(ConversationBlobAccess.references(pictured, attachments: [], messages: [message]))
        #expect(!ConversationBlobAccess.references(String(repeating: "c", count: 64), attachments: [attachment], messages: [message]))
    }

    @Test("A conversation serves an image its messages reference, and 404s one it doesn't, even when it exists")
    func servedThroughTheConversation() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "conversation-blobs")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let referenced = try put(png, into: fixture.local)
        let unreferenced = try put(png + Data([0x00]), into: fixture.local)
        let message = Message(
            id: UUID(), role: .user, content: "look", timestamp: Date(),
            images: [Message.Image(name: "shot.png", path: SessionBlobImageRef.path(for: referenced))], toolCalls: []
        )
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: model(), extraMessages: [message])
        let otherID = try await HarnessConversationTestFixtures.seedRegistryConversation(host: fixture.host, model: model())
        let api = await makeSplitConversationAdapter(runtimeSession: fixture.host)

        let blob = try #require(await api.apiConversationBlob(conversationID: conversationID, blobID: referenced))
        #expect(blob.data == png)
        #expect(blob.mediaType == "image/png")
        #expect(blob.contentHash == referenced)
        #expect(await api.apiConversationBlob(conversationID: conversationID, blobID: unreferenced) == nil)
        #expect(await api.apiConversationBlob(conversationID: otherID, blobID: referenced) == nil, "another conversation's image")
    }
}
