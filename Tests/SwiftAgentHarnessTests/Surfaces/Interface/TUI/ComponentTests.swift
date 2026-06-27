import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TranscriptListComponent")
struct TranscriptListTests {
    @Test("Virtualizes to viewport window")
    func virtualization() {
        let list = TranscriptListComponent(viewportRows: 3, marginRows: 0)
        for index in 0..<20 {
            list.appendMessage(TUIMessage(role: .user, content: "message \(index)"))
        }
        let lines = list.render(width: 40)
        #expect(lines.count <= 3)
    }

    @Test("Active streaming view tracks tail message")
    func streamingView() {
        let list = TranscriptListComponent()
        list.appendMessage(TUIMessage(role: .assistant, content: "", isStreaming: true))
        let view = list.activeStreamingView()
        view?.appendToken("tok")
        #expect(view?.streamingTail == "tok")
    }
}

@Suite("MessageViewComponent")
struct MessageViewTests {
    @Test("Token append and commit")
    func streaming() {
        let view = MessageViewComponent(message: TUIMessage(role: .assistant, content: "Hel", isStreaming: true))
        view.appendToken("lo")
        #expect(view.streamingTail == "lo")
        view.commitStreaming()
        #expect(view.message.content == "Hello")
        #expect(view.streamingTail.isEmpty)
    }
}

@Suite("ApprovalDialogComponent")
struct ApprovalDialogTests {
    @Test("Renders presentation blocks")
    func renderBlocks() {
        let presentation = ApprovalPresentation.standard(title: "Run command?", context: ["rm -rf /tmp/x"])
        let dialog = ApprovalDialogComponent(presentation: presentation, approvalID: "abc")
        let lines = dialog.render(width: 60)
        #expect(!lines.isEmpty)
        #expect(lines.joined().contains("Run command?"))
    }
}

@Suite("OverlayHostComponent")
struct OverlayHostTests {
    @Test("Composites overlay above base")
    func composite() {
        let base = StaticLinesComponent(lines: ["background line"])
        let host = OverlayHostComponent(base: base)
        host.show(StaticLinesComponent(lines: ["MODAL"]))
        let lines = host.render(width: 40)
        #expect(lines.joined().contains("MODAL"))
    }
}

@Suite("SplitComponent")
struct SplitComponentTests {
    @Test("Renders horizontal split")
    func horizontalSplit() {
        let split = SplitComponent(
            primary: StaticLinesComponent(lines: ["left"]),
            secondary: StaticLinesComponent(lines: ["right"])
        )
        let lines = split.render(width: 40)
        #expect(lines.first?.contains("left") == true)
        #expect(lines.first?.contains("right") == true)
    }
}

private final class StaticLinesComponent: TUIComponent {
    var lines: [String]
    init(lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width)) }
    }
}
