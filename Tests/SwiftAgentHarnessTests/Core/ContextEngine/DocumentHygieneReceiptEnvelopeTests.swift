import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Document hygiene receipt envelope")
struct DocumentHygieneReceiptEnvelopeTests {
    private let marker = "[document trimmed]"

    @Test("receipt includes marker, preview, byte count, and message pointer")
    func receiptIncludesRequiredFields() {
        let messageID = UUID()
        let body = String(repeating: "abcdefghij", count: 400)
        let receipt = DocumentHygieneReceiptEnvelope.make(
            originalContent: body,
            messageID: messageID,
            marker: marker,
            previewMaxBytes: 64
        )
        #expect(receipt.contains(marker))
        #expect(receipt.contains("preview:"))
        #expect(receipt.contains("abcdefghij"))
        #expect(receipt.contains("original_byte_count: \(body.utf8.count)"))
        #expect(receipt.contains("message_id: \(messageID.uuidString)"))
        #expect(receipt.contains("Full content is retained in conversation history at message_id \(messageID.uuidString)"))
        #expect(receipt.contains("bytes elided"))
    }

    @Test("isReceiptEnvelope detects existing receipts")
    func detectsExistingReceipt() {
        let messageID = UUID()
        let receipt = DocumentHygieneReceiptEnvelope.make(
            originalContent: String(repeating: "x", count: 200),
            messageID: messageID,
            marker: marker,
            previewMaxBytes: 32
        )
        #expect(DocumentHygieneReceiptEnvelope.isReceiptEnvelope(receipt, marker: marker))
        #expect(!DocumentHygieneReceiptEnvelope.isReceiptEnvelope("plain text", marker: marker))
    }

    @Test("preview uses UTF-8-safe prefix boundaries")
    func previewIsUTF8Safe() {
        let body = "€" + String(repeating: "a", count: 200)
        let receipt = DocumentHygieneReceiptEnvelope.make(
            originalContent: body,
            messageID: UUID(),
            marker: marker,
            previewMaxBytes: 4
        )
        #expect(receipt.contains("original_byte_count: \(body.utf8.count)"))
        #expect(receipt.contains("bytes elided"))
    }
}

@Suite("Deterministic document hygiene policy helper")
struct ContextEngineDocumentHygienePolicyHelperTests {
    private func hygienePolicy(
        threshold: Int = 100,
        previewMaxBytes: Int = 64,
        marker: String = "[document trimmed]"
    ) -> ContextCompactionAttachmentDocumentHygienePolicy {
        ContextCompactionAttachmentDocumentHygienePolicy(
            enabled: true,
            maxImagesPerMessage: 0,
            documentCharacterThreshold: threshold,
            documentPreviewMaxBytes: previewMaxBytes,
            imagePlaceholder: "",
            documentPlaceholder: marker
        )
    }

    @Test("oversized document-like content is replaced with receipt")
    func documentLikeContentGetsReceipt() {
        let messageID = UUID()
        let body = String(repeating: "line\n", count: 50)
        let messages = [
            Message(id: messageID, role: .assistant, content: body, timestamp: Date(), toolCalls: []),
        ]
        let output = ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: messages,
            policy: hygienePolicy()
        )
        #expect(output[0].content.contains("[document trimmed]"))
        #expect(output[0].content.contains("original_byte_count:"))
        #expect(output[0].content.contains("message_id: \(messageID.uuidString)"))
    }

    @Test("fenced code-only messages are not trimmed")
    func fencedCodeIsNotDocumentLike() {
        let code = """
        ```swift
        \(String(repeating: "let payload = \"\(String(repeating: "x", count: 80))\"\n", count: 12))
        ```
        """
        let messageID = UUID()
        let messages = [
            Message(id: messageID, role: .user, content: code, timestamp: Date(), toolCalls: []),
        ]
        let output = ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: messages,
            policy: hygienePolicy(threshold: 50)
        )
        #expect(output[0].content == code)
    }

    @Test("document markers still qualify for trimming")
    func documentMarkerStillTrims() {
        let messageID = UUID()
        let body = "<document>\n" + String(repeating: "x", count: 200)
        let messages = [
            Message(id: messageID, role: .assistant, content: body, timestamp: Date(), toolCalls: []),
        ]
        let output = ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: messages,
            policy: hygienePolicy(threshold: 50)
        )
        #expect(output[0].content.contains("original_byte_count:"))
        #expect(output[0].content.contains("message_id: \(messageID.uuidString)"))
    }

    @Test("existing receipt is not re-wrapped")
    func idempotentReceipt() {
        let messageID = UUID()
        let receipt = DocumentHygieneReceiptEnvelope.make(
            originalContent: String(repeating: "line\n", count: 50),
            messageID: messageID,
            marker: "[document trimmed]",
            previewMaxBytes: 64
        )
        let messages = [
            Message(id: messageID, role: .assistant, content: receipt, timestamp: Date(), toolCalls: []),
        ]
        let output = ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: messages,
            policy: hygienePolicy(threshold: 10)
        )
        #expect(output[0].content == receipt)
    }
}
