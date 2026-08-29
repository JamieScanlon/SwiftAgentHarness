import Foundation
import Testing
@testable import SwiftAgentHarness

/// A single property test standing in for a whole class of crashes.
///
/// Every component's `render(width:)` must honour the line ≤ width invariant at every
/// width, because a violation is not a cosmetic bug: `TUIComponentRender` traps on it,
/// and a trap while the tty is in raw mode leaves the user's shell unusable.
@Suite("Width invariant")
struct WidthInvariantTests {
    private static let widths = Array(1...80) + [100, 120, 160, 200]

    private func assertBounded(_ component: any TUIComponent, label: String) {
        for width in Self.widths {
            let lines = component.render(width: width)
            for (index, line) in lines.enumerated() {
                let visible = ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line))
                #expect(visible <= width, "\(label) line \(index) is \(visible) wide at width \(width)")
            }
        }
    }

    @Test("Box with an ASCII title")
    func boxASCIITitle() {
        assertBounded(
            BoxComponent(title: "Approval Required", child: StaticLines(["body"])),
            label: "Box/ascii"
        )
    }

    @Test("Box with a wide-character title")
    func boxWideTitle() {
        // `label.count` under-counts a CJK title by half, so the border overshot `width`.
        assertBounded(
            BoxComponent(title: "文件差分", child: StaticLines(["body"])),
            label: "Box/cjk"
        )
    }

    @Test("Split at every width")
    func split() {
        assertBounded(
            SplitComponent(primary: StaticLines(["left pane"]), secondary: StaticLines(["right pane"])),
            label: "Split"
        )
    }

    @Test("Vertical split at every width")
    func verticalSplit() {
        assertBounded(
            SplitComponent(
                orientation: .vertical,
                primary: StaticLines(["top"]),
                secondary: StaticLines(["bottom"])
            ),
            label: "Split/vertical"
        )
    }

    @Test("Stack at every width")
    func stack() {
        assertBounded(
            StackComponent(children: [StaticLines(["a", "b"]), StaticLines(["c"])]),
            label: "Stack"
        )
    }

    @Test("Approval dialog at every width")
    func approvalDialog() {
        let presentation = ApprovalPresentation.standard(
            title: "Run this command?",
            context: ["rm -rf /tmp/example", "cwd: /Users/someone/projects"]
        )
        assertBounded(
            ApprovalDialogComponent(presentation: presentation, approvalID: "a1"),
            label: "ApprovalDialog"
        )
    }

    @Test("Mode dialog at every width")
    func modeDialog() {
        // Its `max(20, …)` floor ignored narrow widths entirely and had no final clamp.
        assertBounded(
            ModeDialogComponent(
                title: "Interaction mode",
                options: [
                    ModeOption(id: "plan", label: "Plan", detail: "read-only exploration"),
                    ModeOption(id: "build", label: "Build", detail: "edits allowed"),
                ]
            ),
            label: "ModeDialog"
        )
    }

    @Test("Overlay host compositing an unclamped dialog")
    func overlayHost() {
        let host = OverlayHostComponent(base: StaticLines(["base line one", "base line two"]))
        host.show(
            ModeDialogComponent(
                title: "Interaction mode",
                options: [ModeOption(id: "plan", label: "Plan")]
            )
        )
        assertBounded(host, label: "OverlayHost")
    }

    @Test("Composer with content and autocomplete")
    func composer() {
        let composer = InputComposerComponent(lines: ["/help something", "second line"])
        composer.autocomplete = AutocompletePopupComponent(
            suggestions: [
                AutocompleteSuggestion(id: "help", label: "/help", detail: "show commands"),
                AutocompleteSuggestion(id: "model", label: "/model", detail: "switch model"),
            ]
        )
        assertBounded(composer, label: "Composer")
    }

    @Test("Transcript with wrapped and styled content")
    func transcript() {
        let list = TranscriptListComponent(viewportRows: 6)
        list.appendMessage(TUIMessage(role: .user, content: "a problem with the algorithm"))
        list.appendMessage(TUIMessage(role: .assistant, content: String(repeating: "word ", count: 30)))
        list.appendMessage(TUIMessage(role: .system, content: "日本語のテキストと emoji \u{1F600}"))
        assertBounded(list, label: "Transcript")
    }

    @Test("File diff view at every width")
    func fileDiffView() {
        // Its header went straight into the line list unclamped; a long path tripped the
        // width invariant and aborted the process.
        assertBounded(
            FileDiffViewComponent(
                filePath: "/Users/someone/projects/a/very/long/path/to/Source.swift",
                hunks: [
                    FileDiffHunk(
                        oldStart: 10,
                        newStart: 12,
                        lines: [
                            FileDiffLine(kind: .context, text: "let algorithm = compute()"),
                            FileDiffLine(kind: .addition, text: "let 日本語 = compute() // 😀"),
                            FileDiffLine(kind: .deletion, text: "let problem = compute()"),
                        ]
                    )
                ]
            ),
            label: "FileDiffView"
        )
    }

    @Test("Expanded reasoning view at every width")
    func reasoningView() {
        let view = ReasoningViewComponent(text: "a long stream of reasoning about the algorithm", collapsed: false)
        assertBounded(view, label: "ReasoningView")
    }

    @Test("Tool pane at every width")
    func toolPane() {
        let pane = ToolPaneViewComponent(
            toolName: "bash",
            argumentsFragment: "{\"command\": \"echo hello world\"}",
            output: String(repeating: "output ", count: 12)
        )
        assertBounded(pane, label: "ToolPane")
    }

    @Test("Status line with every field populated")
    func statusLine() {
        let status = StatusLineComponent(
            phase: "thinking",
            modelName: "some-very-long-model-identifier",
            tokenCount: 123_456,
            showSpinner: true
        )
        assertBounded(status, label: "StatusLine")
    }

    @Test("Transcript carrying a native presentation at every width")
    func presentationTranscript() {
        let list = TranscriptListComponent(viewportRows: 8)
        list.appendMessage(
            TUIMessage(
                role: .assistant,
                content: "fallback",
                presentation: MessagePresentation(
                    title: "A fairly long presentation title that must wrap",
                    tone: .warning,
                    blocks: [
                        .text("body text that is long enough to need wrapping at most widths"),
                        .context("context line"),
                        .divider,
                        .buttons([
                            ApprovalButton(id: "a", label: "Allow once"),
                            ApprovalButton(id: "b", label: "Always allow", style: .primary),
                            ApprovalButton(id: "c", label: "Deny", style: .danger),
                        ]),
                    ]
                )
            )
        )
        assertBounded(list, label: "Transcript/presentation")
    }

    @Test("Full app tree at every width")
    func fullTree() {
        let transcript = TranscriptListComponent(viewportRows: 6)
        transcript.appendMessage(TUIMessage(role: .user, content: "hello there"))
        let composer = InputComposerComponent(lines: ["typing"])
        let status = StatusLineComponent(phase: "idle")
        let toolPane = ToolPaneViewComponent()
        let reasoning = ReasoningViewComponent()
        let split = SplitComponent(
            primary: StackComponent(children: [transcript, reasoning]),
            secondary: toolPane
        )
        let host = OverlayHostComponent(
            base: StackComponent(focusedIndex: 2, children: [split, status, composer])
        )
        assertBounded(host, label: "AppTree")
    }
}

private final class StaticLines: TUIComponent {
    var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width)) }
    }
}
