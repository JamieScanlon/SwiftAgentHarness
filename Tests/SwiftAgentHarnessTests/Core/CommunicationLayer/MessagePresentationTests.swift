import Foundation
import Logging
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Message presentation")
struct MessagePresentationTests {
    @Test("text fallback renders title blocks buttons and select")
    func textFallback() {
        let presentation = MessagePresentation(
            title: "Title",
            tone: .info,
            blocks: [
                .text("Body"),
                .context("Meta"),
                .divider,
                .buttons([ApprovalButton(id: "ok", label: "OK")]),
                .select(options: [MessageSelectOption(id: "a", label: "A")], label: "Pick"),
            ]
        )
        let text = presentation.textFallback()
        #expect(text.contains("Title"))
        #expect(text.contains("Body"))
        #expect(text.contains("Meta"))
        #expect(text.contains("---"))
        #expect(text.contains("OK"))
        #expect(text.contains("Pick"))
    }

    @Test("approval presentation maps to message presentation")
    func approvalMapping() {
        let approval = ApprovalPresentation.standard(title: "Approve?", context: ["rm -rf ./tmp"])
        let message = approval.asMessagePresentation()
        #expect(message.textFallback().contains("Approve?"))
        #expect(message.textFallback().contains("rm -rf ./tmp"))
    }
}

@Suite("Message output post processor")
struct MessageOutputPostProcessorTests {
    @Test("message tool only replaces assistant content from message tool args")
    func messageToolOnly() {
        let toolCall = ToolCall(
            name: MessageToolArgumentsParser.toolName,
            arguments: .object([
                "blocks": .string(#"[{"type":"text","text":"Delivered"}]"#),
            ]),
            id: "call-1"
        )
        let envelope = HarnessMessageEnvelope(
            message: Message(
                id: UUID(),
                role: .assistant,
                content: "raw prose",
                timestamp: Date(),
                toolCalls: [toolCall]
            )
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .messageToolOnly)
        #expect(processed.message.content == "Delivered")
    }

    @Test("legacy policy preserves assistant content")
    func legacyPreserves() {
        let envelope = HarnessMessageEnvelope(
            message: Message(id: UUID(), role: .assistant, content: "hello", timestamp: Date())
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .legacyStreamedText)
        #expect(processed.message.content == "hello")
    }

    @Test("message tool only clears bare prose without message tool")
    func bareProseEmpty() {
        let envelope = HarnessMessageEnvelope(
            message: Message(
                id: UUID(),
                role: .assistant,
                content: "raw prose only",
                timestamp: Date(),
                toolCalls: []
            )
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .messageToolOnly)
        #expect(processed.message.content == "")
    }
}
