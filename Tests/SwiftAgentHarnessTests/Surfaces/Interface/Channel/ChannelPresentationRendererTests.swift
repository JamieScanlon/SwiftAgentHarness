import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelPresentationRenderer")
struct ChannelPresentationRendererTests {
    @Test("unsupported capabilities use text fallback only")
    func unsupportedUsesTextFallback() {
        let presentation = MessagePresentation(
            title: "Title",
            blocks: [
                .text("body"),
                .divider,
                .buttons([ApprovalButton(id: "ok", label: "OK")]),
            ]
        )
        let capabilities = ChannelPresentationCapabilities(
            supported: false,
            buttons: true,
            selects: false,
            context: true,
            divider: true
        )
        let rendered = ChannelPresentationRenderer.render(presentation, capabilities: capabilities)
        #expect(rendered.richPresentation == nil)
        #expect(rendered.text == presentation.textFallback())
    }

    @Test("supported capabilities preserve native block structure")
    func supportedPreservesBlocks() throws {
        let buttons = [ApprovalButton(id: "ok", label: "OK")]
        let presentation = MessagePresentation(
            title: "Title",
            tone: .info,
            blocks: [
                .text("body"),
                .context("footnote"),
                .divider,
                .buttons(buttons),
            ]
        )
        let rendered = ChannelPresentationRenderer.render(
            presentation,
            capabilities: .mockRich
        )
        let rich = try #require(rendered.richPresentation)
        #expect(rich.title == "Title")
        #expect(rich.tone == .info)
        #expect(rich.blocks.count == 4)
        #expect(rich.blocks.contains(.divider))
        if case .buttons(let renderedButtons) = rich.blocks[3] {
            #expect(renderedButtons == buttons)
        } else {
            Issue.record("expected buttons block in rich presentation")
        }
        #expect(rendered.text == presentation.textFallback())
        #expect(rendered.text.contains("OK"))
    }

    @Test("partial capabilities omit unsupported blocks from rich payload")
    func partialCapabilitiesDegradeBlocks() throws {
        let presentation = MessagePresentation(
            blocks: [
                .text("body"),
                .buttons([ApprovalButton(id: "ok", label: "OK")]),
            ]
        )
        let capabilities = ChannelPresentationCapabilities(
            supported: true,
            buttons: false,
            selects: false,
            context: true,
            divider: true
        )
        let rendered = ChannelPresentationRenderer.render(presentation, capabilities: capabilities)
        let rich = try #require(rendered.richPresentation)
        #expect(rich.blocks == [.text("body")])
        #expect(rendered.text.contains("OK"))
    }

    @Test("sendPayload delivers rich message in one shot")
    func sendPayloadRichSingleMessage() async {
        let config = ChannelListenerConfig(platformIdentity: "mock")
        let listener = MockChannelListener(id: .slack, config: config, logger: Logger(label: "test"))
        let outbound = DefaultChannelOutboundAdapter(
            listener: listener,
            chunkLimit: 20,
            presentationCapabilities: .mockRich
        )
        let presentation = MessagePresentation(blocks: [.text(String(repeating: "x", count: 50))])
        let payload = outbound.renderPresentation(presentation)
        #expect(payload.richPresentation != nil)
        _ = await outbound.sendPayload(
            payload,
            target: ChannelDeliveryTarget(chatId: "C1", threadId: nil, replyToMessageId: nil)
        )
        #expect(listener.sentMessages.count == 1)
        #expect(listener.sentMessages[0].richPresentation != nil)
    }

    @Test("sendPayload chunks text-only payloads")
    func sendPayloadChunksTextOnly() async {
        let config = ChannelListenerConfig(platformIdentity: "mock")
        let listener = MockChannelListener(id: .slack, config: config, logger: Logger(label: "test"))
        let outbound = DefaultChannelOutboundAdapter(
            listener: listener,
            chunkLimit: 20,
            presentationCapabilities: ChannelPresentationCapabilities(
                supported: false,
                buttons: false,
                selects: false,
                context: false,
                divider: false
            )
        )
        let payload = ChannelRenderedPayload(text: String(repeating: "y", count: 50))
        _ = await outbound.sendPayload(
            payload,
            target: ChannelDeliveryTarget(chatId: "C1", threadId: nil, replyToMessageId: nil)
        )
        #expect(listener.sentMessages.count > 1)
        #expect(listener.sentMessages.allSatisfy { $0.richPresentation == nil })
    }
}
