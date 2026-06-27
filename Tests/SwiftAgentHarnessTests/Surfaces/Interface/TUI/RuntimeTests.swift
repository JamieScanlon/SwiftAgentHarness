import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TUIStreamingSurfaceSinkLogic")
struct TUIStreamingSurfaceSinkTests {
    @Test("Token deltas append to active streaming message")
    func tokenDelta() {
        let transcript = TranscriptListComponent()
        TUIStreamingSurfaceSinkLogic.sendTokenDelta("Hel", to: transcript)
        TUIStreamingSurfaceSinkLogic.sendTokenDelta("lo", to: transcript)
        TUIStreamingSurfaceSinkLogic.sendFinal(StreamingFinalPayload(text: "Hello"), to: transcript)
        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].content == "Hello")
    }

    @Test("Cancellation annotates partial output")
    func cancellation() {
        let transcript = TranscriptListComponent()
        TUIStreamingSurfaceSinkLogic.sendTokenDelta("partial", to: transcript)
        TUIStreamingSurfaceSinkLogic.emitCancellation(CancellationNotice(marker: " [cancelled]"), to: transcript)
        #expect(transcript.messages.first?.content.contains("partial") == true)
    }
}

@Suite("TUIApp integration")
struct TUIAppIntegrationTests {
    @Test("Ingests streaming partials and renders frame")
    func ingestAndRender() async {
        let term = VirtualTerminal(columns: 80, rows: 24)
        let app = TUIApp(terminal: term)
        await app.ingest(.text("Hello"))
        await app.finishTurn(final: StreamingFinalPayload(text: "Hello"))
        #expect(!term.rawOutput.isEmpty)
        #expect(await app.messageCount() == 1)
    }

    @Test("Shows approval overlay from surface intent")
    func approvalOverlay() async {
        let term = VirtualTerminal(columns: 80, rows: 24)
        let app = TUIApp(terminal: term)
        let presentation = ApprovalPresentation.standard(title: "Approve?")
        await app.ingest(.surfaceIntent(ClientSurfaceIntent(
            kind: .execApprovalRequired,
            approvalID: "a1",
            presentation: presentation
        )))
        let lines = await app.renderOverlay(width: 80)
        #expect(lines.joined().contains("Approve?"))
    }
}

@Suite("InlineImageRenderer")
struct InlineImageTests {
    @Test("Text fallback when no protocol supported")
    func fallback() {
        let image = InlineImage(data: Data([0x01, 0x02]), width: 10, height: 5, altText: "chart")
        let rendered = InlineImageRenderer.render(image, capabilities: .none)
        #expect(rendered == "[chart 10×5]")
    }

    @Test("Kitty encoder emits graphics APC")
    func kitty() {
        let image = InlineImage(data: Data([0xFF]), width: 2, height: 2, altText: "dot")
        let rendered = InlineImageRenderer.render(image, capabilities: InlineImageCapabilities(kitty: true))
        #expect(rendered.contains("_G"))
    }

    @Test("iTerm2 encoder emits 1337 sequence")
    func iterm2() {
        let image = InlineImage(data: Data([0xFF]), width: 2, height: 2, altText: "dot")
        let rendered = InlineImageRenderer.render(image, capabilities: InlineImageCapabilities(iterm2: true))
        #expect(rendered.contains("1337"))
    }
}

@Suite("CachingComponent")
struct CachingComponentTests {
    @Test("Caches until invalidated")
    func caching() {
        let inner = CountingComponent()
        let cached = CachingComponent(inner, context: "count")
        _ = cached.render(width: 40)
        _ = cached.render(width: 40)
        #expect(inner.renderCount == 1)
        cached.invalidate()
        _ = cached.render(width: 40)
        #expect(inner.renderCount == 2)
    }
}

private final class CountingComponent: TUIComponent {
    var renderCount = 0
    func render(width: Int) -> [String] {
        renderCount += 1
        return [ANSIStyle.finishLine("x")]
    }
}
