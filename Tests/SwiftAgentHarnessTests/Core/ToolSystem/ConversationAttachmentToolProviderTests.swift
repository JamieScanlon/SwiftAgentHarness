import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationAttachmentToolProvider")
struct ConversationAttachmentToolProviderTests {
    private func makeConversation(
        id: UUID = UUID(),
        attachments: [ConversationAttachmentDescriptor]
    ) -> ModelConversation {
        ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s",
            attachmentsCatalog: attachments
        )
    }

    private func makeProvider(
        conversation: ModelConversation,
        harness: InMemoryHarnessSessionPersistence
    ) -> ConversationAttachmentToolProvider {
        ConversationAttachmentToolProvider(
            resolveConversation: { conversation },
            readAttachmentBytes: { attachmentID, conversationID in
                let descriptor = try ConversationAttachmentBlobAccess.resolve(
                    attachmentID: attachmentID,
                    catalog: conversation.attachmentsCatalog
                )
                let data = try ConversationAttachmentBlobAccess.loadBytes(
                    descriptor: descriptor,
                    conversationID: conversationID,
                    harness: harness
                )
                return (descriptor, data)
            }
        )
    }

    private func storeBlob(
        harness: InMemoryHarnessSessionPersistence,
        data: Data,
        mimeType: String = "text/plain"
    ) throws -> String {
        try harness.putBlob(
            data: data,
            durability: .durable,
            originalName: "sample.txt",
            mimeType: mimeType,
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        ).id
    }

    @Test("read_attachment returns UTF-8 text for catalog-backed blob")
    func readsTextAttachment() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let attachmentID = UUID()
        let blobId = try storeBlob(harness: harness, data: Data("hello attachment".utf8))
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: 16,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let conversation = makeConversation(id: conversationID, attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-1"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(result.content == "hello attachment")
    }

    @Test("read_attachment rejects unknown attachment_id in conversation catalog")
    func unknownAttachmentFails() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversation = makeConversation(attachments: [])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(UUID().uuidString)]),
            id: "tc-2"
        )
        let result = try await provider.executeTool(call)
        #expect(!result.success)
        #expect(result.content.contains("attachment not found in this conversation"))
    }

    @Test("read_attachment reports missing blob reference")
    func missingBlobReferenceFails() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            kind: "document",
            name: "orphan.txt",
            mimeType: "text/plain",
            byteSize: 10,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-3"
        )
        let result = try await provider.executeTool(call)
        #expect(!result.success)
        #expect(result.content.contains("no blob reference"))
    }

    @Test("read_attachment requires windowing guidance for oversized text")
    func oversizedTextRequiresWindowing() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let largeText = String(repeating: "x", count: ReadFileWindowing.maxReadBytes + 1)
        let blobId = try storeBlob(harness: harness, data: Data(largeText.utf8))
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "large.txt",
            mimeType: "text/plain",
            byteSize: Int64(largeText.utf8.count),
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-4"
        )
        let result = try await provider.executeTool(call)
        #expect(!result.success)
        #expect(result.content == ReadFileWindowing.exceedsCapGuidance)
    }

    @Test("read_attachment wraps low-trust attachment content")
    func lowTrustAttachmentIsEnvelopeWrapped() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let blobId = try storeBlob(harness: harness, data: Data("untrusted".utf8))
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "fetched.txt",
            mimeType: "text/plain",
            byteSize: 9,
            trustRaw: AttachmentInputTrust.scripted.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-5"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(ExternalContentEnvelope.isAlreadyWrapped(result.content))
    }

    @Test("read_attachment leaves user-direct content plain")
    func userDirectAttachmentStaysPlain() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let blobId = try storeBlob(harness: harness, data: Data("trusted".utf8))
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: 7,
            trustRaw: CommEnvelopeOriginTrust.userDirect.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-user-direct"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(result.content == "trusted")
        #expect(!ExternalContentEnvelope.isAlreadyWrapped(result.content))
    }

    @Test("read_attachment agent-fetched unknown-party includes web_fetch source label")
    func agentFetchedUnknownPartyUsesWebFetchSource() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let blobId = try storeBlob(harness: harness, data: Data("fetched".utf8))
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "page.html",
            mimeType: "text/html",
            byteSize: 7,
            addedBy: .agent,
            trustRaw: CommEnvelopeOriginTrust.unknownParty.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-agent-fetch"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(ExternalContentEnvelope.isAlreadyWrapped(result.content))
        #expect(result.content.contains("Web fetch"))
    }

    @Test("read_attachment returns honest binary marker for non-text bytes")
    func binaryAttachmentReturnsHonestMarker() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let attachmentID = UUID()
        let blobId = try storeBlob(
            harness: harness,
            data: Data([0x00, 0x01, 0x02, 0x03]),
            mimeType: "application/octet-stream"
        )
        let descriptor = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobId,
            kind: "document",
            name: "data.bin",
            mimeType: "application/octet-stream",
            byteSize: 4,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let conversation = makeConversation(attachments: [descriptor])
        let provider = makeProvider(conversation: conversation, harness: harness)
        let call = ToolCall(
            name: ConversationAttachmentToolProvider.readAttachmentToolName,
            arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
            id: "tc-6"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(result.content.contains("binary attachment"))
        #expect(result.content.contains("original_byte_count: 4"))
        #expect(!result.content.contains("\u{0}"))
    }

    @Test("read_attachment is spill-exempt")
    func spillExempt() {
        #expect(ToolRegistrySpillPolicy.isSpillExempt(toolName: "read_attachment"))
    }

    @Test("ToolExternalContentPolicy exempts read_attachment from generic wrapping")
    func externalContentPolicyExempt() {
        let decision = ToolExternalContentPolicy.resolve(
            toolName: ConversationAttachmentToolProvider.readAttachmentToolName,
            entry: nil
        )
        #expect(!decision.shouldWrap)
    }
}
