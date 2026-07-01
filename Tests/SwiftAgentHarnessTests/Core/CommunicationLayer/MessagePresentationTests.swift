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
    @Test("prose preserved when message call present")
    func prosePreservedWithMessageCall() {
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
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .structuredPreferred)
        #expect(processed.message.content == "raw prose")
        #expect(processed.message.toolCalls.count == 1)
    }

    @Test("streamed prose policy preserves assistant content")
    func streamedProsePreserves() {
        let envelope = HarnessMessageEnvelope(
            message: Message(id: UUID(), role: .assistant, content: "hello", timestamp: Date())
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .streamedProse)
        #expect(processed.message.content == "hello")
    }

    @Test("prose preserved without message tool")
    func prosePreservedWithoutMessageTool() {
        let envelope = HarnessMessageEnvelope(
            message: Message(
                id: UUID(),
                role: .assistant,
                content: "raw prose only",
                timestamp: Date(),
                toolCalls: []
            )
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .structuredPreferred)
        #expect(processed.message.content == "raw prose only")
    }

    @Test("structured-only reply uses textFallback")
    func structuredOnlyUsesTextFallback() {
        let toolCall = ToolCall(
            name: MessageToolArgumentsParser.toolName,
            arguments: .object([
                "blocks": .string(#"[{"type":"text","text":"Structured only"}]"#),
            ]),
            id: "call-1"
        )
        let envelope = HarnessMessageEnvelope(
            message: Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [toolCall]
            )
        )
        let processed = MessageOutputPostProcessor.apply(envelope: envelope, policy: .structuredPreferred)
        #expect(processed.message.content == "Structured only")
    }
}
