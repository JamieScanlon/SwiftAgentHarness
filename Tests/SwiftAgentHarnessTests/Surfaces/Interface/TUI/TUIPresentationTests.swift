import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("MessagePresentationTerminalRenderer")
struct MessagePresentationTerminalRendererTests {
    @Test("Renders every supported block natively")
    func rendersBlocks() {
        let presentation = MessagePresentation(
            title: "Deploy check",
            tone: .warning,
            blocks: [
                .text("Ready to ship?"),
                .context("build 1423"),
                .divider,
                .buttons([
                    ApprovalButton(id: "yes", label: "Ship", style: .primary),
                    ApprovalButton(id: "no", label: "Hold", style: .danger),
                ]),
            ]
        )
        let joined = MessagePresentationTerminalRenderer.render(presentation, width: 60)
            .map { ANSIWidth.stripANSI($0) }
            .joined(separator: "\n")

        #expect(joined.contains("Deploy check"))
        #expect(joined.contains("Ready to ship?"))
        #expect(joined.contains("build 1423"))
        #expect(joined.contains("[ Ship ]"))
        #expect(joined.contains("[ Hold ]"))
        #expect(joined.contains("─"))
    }

    @Test("Every rendered line honours the width bound")
    func widthBound() {
        let presentation = MessagePresentation(
            title: String(repeating: "long title ", count: 8),
            tone: .error,
            blocks: [
                .text(String(repeating: "body text ", count: 20)),
                .context(String(repeating: "ctx ", count: 20)),
                .divider,
                .buttons([ApprovalButton(id: "a", label: String(repeating: "L", count: 40))]),
            ]
        )
        for width in 1...80 {
            for line in MessagePresentationTerminalRenderer.render(presentation, width: width) {
                #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) <= width)
            }
        }
    }

    @Test("Select blocks degrade to a bulleted list")
    func selectDegrades() {
        // `select` is outside the terminal's declared capabilities, so it is filtered out
        // of a normal render — but rendering the block directly must still say something.
        let joined = MessagePresentationTerminalRenderer.render(
            MessagePresentation(blocks: [.select(options: [MessageSelectOption(id: "a", label: "Alpha")], label: "Pick one")]),
            width: 40
        ).map { ANSIWidth.stripANSI($0) }.joined(separator: "\n")
        #expect(joined.contains("Alpha") || joined.contains("Pick one"))
    }

    @Test("Presentation text is sanitized before it reaches a frame")
    func sanitizesHostileText() {
        let presentation = MessagePresentation(blocks: [.text("safe\u{1B}[31mred\u{1B}[0m")])
        let joined = MessagePresentationTerminalRenderer.render(presentation, width: 40).joined()
        #expect(!joined.contains("\u{1B}[31m"))
        #expect(ANSIWidth.stripANSI(joined).contains("safered"))
    }

    @Test("An all-unsupported presentation still renders its text floor")
    func fallsBackWhenNothingSupported() {
        let presentation = MessagePresentation(blocks: [.select(options: [], label: nil)])
        let lines = MessagePresentationTerminalRenderer.render(presentation, width: 40)
        #expect(!lines.isEmpty)
    }
}

@Suite("MessageView presentation rendering")
struct MessageViewPresentationTests {
    @Test("Renders the presentation natively rather than the text floor")
    func rendersNatively() {
        let presentation = MessagePresentation(
            blocks: [.buttons([ApprovalButton(id: "ok", label: "Confirm")])]
        )
        let view = MessageViewComponent(
            message: TUIMessage(
                role: .assistant,
                content: presentation.textFallback(),
                presentation: presentation
            )
        )
        let joined = view.render(width: 50).map { ANSIWidth.stripANSI($0) }.joined()
        #expect(joined.contains("[ Confirm ]"))
    }

    @Test("Falls back to text while still streaming")
    func fallbackWhileStreaming() {
        let presentation = MessagePresentation(blocks: [.text("done")])
        let view = MessageViewComponent(
            message: TUIMessage(
                role: .assistant,
                content: "partial",
                isStreaming: true,
                presentation: presentation
            )
        )
        let joined = view.render(width: 50).map { ANSIWidth.stripANSI($0) }.joined()
        #expect(joined.contains("partial"))
    }

    @Test("Messages without a presentation are unaffected")
    func plainMessageUnchanged() {
        let view = MessageViewComponent(message: TUIMessage(role: .user, content: "hello"))
        let joined = view.render(width: 50).map { ANSIWidth.stripANSI($0) }.joined()
        #expect(joined.contains("hello"))
    }
}

@Suite("TUI message-output delivery")
struct TUIMessageOutputDeliveryTests {
    @Test("Delivered presentations land in the transcript with their text floor")
    func deliverAppends() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 14))
        let presentation = MessagePresentation(
            title: "Result",
            blocks: [.text("all good"), .buttons([ApprovalButton(id: "ok", label: "OK")])]
        )
        await app.deliver(presentation: presentation)

        let messages = await app.transcriptMessages()
        #expect(messages.count == 1)
        #expect(messages[0].presentation == presentation)
        #expect(messages[0].content == presentation.textFallback())
    }

    @Test("Delivery mid-turn commits the streaming message instead of splitting it")
    func deliverMidTurnCommits() async {
        // The `message` tool commits while the assistant message is still streaming.
        // Appending on top of it stranded `activeStreamingView()`, so the rest of the
        // turn opened a third message and `sendFinal` wrote the whole turn into it —
        // showing the pre-tool prose twice.
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 14))
        await app.ingest(.text("thinking out loud "))
        await app.deliver(presentation: MessagePresentation(blocks: [.text("tool output")]))
        await app.ingest(.text("and the conclusion"))
        await app.finishTurn()

        let messages = await app.transcriptMessages()
        #expect(messages.count == 3)
        #expect(messages[0].content.contains("thinking out loud"))
        #expect(messages[1].presentation != nil)
        // The final message must carry only the post-tool text, not the whole turn.
        #expect(messages[2].content.contains("and the conclusion"))
        #expect(!messages[2].content.contains("thinking out loud"))
        #expect(messages[0].isStreaming == false)
    }

    @Test("The deliverer routes into the app")
    func delivererRoutes() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 14))
        let deliverer = TUIMessageOutputDeliverer(app: app)
        let conversationID = UUID()
        await deliverer.deliver(
            presentation: MessagePresentation(blocks: [.text("routed")]),
            conversationID: conversationID,
            metadata: MessageOutputDeliveryMetadata(originSurface: InteractiveSurfaceID.tui)
        )
        #expect(await app.messageCount() == 1)
    }

    @Test("Deliveries for another conversation are ignored")
    func filtersByConversation() async {
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 14))
        let mine = UUID()
        let deliverer = TUIMessageOutputDeliverer(app: app, conversationID: mine)
        await deliverer.deliver(
            presentation: MessagePresentation(blocks: [.text("other")]),
            conversationID: UUID(),
            metadata: MessageOutputDeliveryMetadata(originSurface: InteractiveSurfaceID.tui)
        )
        #expect(await app.messageCount() == 0)

        await deliverer.deliver(
            presentation: MessagePresentation(blocks: [.text("mine")]),
            conversationID: mine,
            metadata: MessageOutputDeliveryMetadata(originSurface: InteractiveSurfaceID.tui)
        )
        #expect(await app.messageCount() == 1)
    }

    @Test("Registration makes the registry route TUI output instead of dropping it")
    func registrationRoundTrip() async {
        // Before this, `MessageOutputDeliveryRegistry.deliver` returned silently for
        // originSurface "tui" and every structured message degraded to its text fallback.
        let app = TUIApp(terminal: VirtualTerminal(columns: 60, rows: 14))
        let surfaceID = "tui-registration-test"
        let registration = TUISurfaceRegistration(plugin: TUISurfacePlugin(surfaceID: surfaceID))
        await registration.register(app: app)

        await MessageOutputDeliveryRegistry.shared.deliver(
            presentation: MessagePresentation(blocks: [.text("via registry")]),
            conversationID: UUID(),
            metadata: MessageOutputDeliveryMetadata(originSurface: surfaceID)
        )
        #expect(await app.messageCount() == 1)

        await registration.unregister()
        await MessageOutputDeliveryRegistry.shared.deliver(
            presentation: MessagePresentation(blocks: [.text("dropped")]),
            conversationID: UUID(),
            metadata: MessageOutputDeliveryMetadata(originSurface: surfaceID)
        )
        #expect(await app.messageCount() == 1)
    }
}
