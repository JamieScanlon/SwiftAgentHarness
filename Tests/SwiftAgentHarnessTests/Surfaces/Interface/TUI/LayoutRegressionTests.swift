import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SplitComponent regressions")
struct SplitComponentRegressionTests {
    @Test("Panes are laid out at the ratio they were rendered at")
    func ratioIsHonoured() {
        // Children were rendered at `ratio` and then laid out at a hard-coded 50/50, so
        // the primary pane lost the difference off its right edge on every line.
        let primary = StaticLines([String(repeating: "L", count: 200)])
        let secondary = StaticLines([String(repeating: "R", count: 200)])
        let split = SplitComponent(ratio: 0.6, primary: primary, secondary: secondary)
        let line = split.render(width: 101)[0]
        let visible = ANSIWidth.stripANSI(line)
        let leftCount = visible.prefix(while: { $0 == "L" }).count
        #expect(leftCount == 60)
        #expect(ANSIWidth.visibleWidth(of: line) == 101)
    }

    @Test("Content is not silently re-truncated with an ellipsis")
    func noDoubleTruncation() {
        let primary = StaticLines(["exactly sixty characters of primary pane content here ok!!"])
        let split = SplitComponent(ratio: 0.6, primary: primary, secondary: StaticLines(["r"]))
        let visible = ANSIWidth.stripANSI(split.render(width: 100)[0])
        #expect(visible.hasPrefix("exactly sixty characters of primary pane content here ok!!"))
    }

    @Test("Tab moves focus between panes and sets isFocused")
    func focusTraversal() {
        let primary = FocusableLines(["left"])
        let secondary = FocusableLines(["right"])
        let split = SplitComponent(primary: primary, secondary: secondary)
        split.focusPrimary()
        #expect(primary.isFocused)
        #expect(!secondary.isFocused)
        split.handleInput("\u{09}")
        #expect(!primary.isFocused)
        #expect(secondary.isFocused)
    }

    @Test("Degrades to a single pane below the minimum width")
    func narrowDegrades() {
        let split = SplitComponent(primary: StaticLines(["L"]), secondary: StaticLines(["R"]))
        for width in 1...3 {
            for line in split.render(width: width) {
                #expect(ANSIWidth.visibleWidth(of: line) <= width)
            }
        }
    }

    @Test("Vertical split renders each child once")
    func verticalRendersOnce() {
        let primary = CountingLines(["top"])
        let secondary = CountingLines(["bottom"])
        let split = SplitComponent(orientation: .vertical, primary: primary, secondary: secondary)
        _ = split.render(width: 40)
        #expect(primary.renderCount == 1)
        #expect(secondary.renderCount == 1)
    }
}

@Suite("OverlayHostComponent regressions")
struct OverlayHostRegressionTests {
    @Test("Overlay rows share one left edge")
    func alignedLeftEdge() {
        // `prefixSlice` truncated but never padded, so each overlay row was spliced at
        // that base row's own width — giving a boxed dialog a ragged left border.
        let base = StaticLines(["short", "a much longer base line here", "mid length"])
        let host = OverlayHostComponent(base: base, anchor: .center)
        host.show(StaticLines(["┌──┐", "│AB│", "└──┘"]))
        let lines = host.render(width: 40).map { ANSIWidth.stripANSI($0) }

        let columns = lines.compactMap { line -> Int? in
            guard let index = line.firstIndex(where: { $0 == "┌" || $0 == "│" || $0 == "└" }) else { return nil }
            return line.distance(from: line.startIndex, to: index)
        }
        #expect(columns.count == 3)
        #expect(Set(columns).count == 1)
    }

    @Test("An overlay taller than the base keeps every row")
    func tallOverlayKeepsRows() {
        // Rows past the base were dropped, which loses a dialog's button row — the only
        // way to resolve it.
        let host = OverlayHostComponent(base: StaticLines(["only one base line"]))
        host.show(StaticLines(["one", "two", "three", "BUTTONS"]))
        let joined = host.render(width: 40).joined()
        #expect(joined.contains("BUTTONS"))
    }

    @Test("A modal captures input instead of leaking it to the base")
    func modalCaptures() {
        // When the overlay was not Focusable the keystroke was delivered twice, to two
        // different components.
        let base = RecordingComponent()
        let overlay = RecordingComponent()
        let host = OverlayHostComponent(base: base)
        host.show(overlay)
        host.handleInput("x")
        #expect(overlay.received == ["x"])
        #expect(base.received.isEmpty)
    }

    @Test("Escape dismisses and notifies")
    func escapeDismisses() {
        let host = OverlayHostComponent(base: StaticLines(["base"]))
        let flag = BoolBox()
        host.onOverlayDismissed = { flag.set() }
        host.show(StaticLines(["modal"]))
        host.handleInput("\u{1B}")
        #expect(!host.hasOverlay)
        #expect(flag.value)
    }

    @Test("show and dismiss move focus")
    func focusMoves() {
        let composer = InputComposerComponent()
        let base = StackComponent(focusedIndex: 0, children: [composer])
        let host = OverlayHostComponent(base: base)
        let modal = FocusableLines(["modal"])
        host.show(modal)
        #expect(!composer.isFocused)
        #expect(modal.isFocused)
        host.dismissOverlay()
        #expect(composer.isFocused)
    }
}

@Suite("StackComponent regressions")
struct StackComponentRegressionTests {
    @Test("Input goes to one child, not every child")
    func singleRecipient() {
        let first = RecordingComponent()
        let second = RecordingComponent()
        let stack = StackComponent(focusedIndex: 1, children: [first, second])
        stack.handleInput("k")
        #expect(first.received.isEmpty)
        #expect(second.received == ["k"])
    }

    @Test("Falls back to the focused child when no index is set")
    func focusedChildFallback() {
        let plain = RecordingComponent()
        let focusable = FocusableLines(["x"])
        focusable.isFocused = true
        let stack = StackComponent(children: [plain, focusable])
        stack.handleInput("k")
        #expect(plain.received.isEmpty)
        #expect(focusable.received == ["k"])
    }
}

@Suite("BoxComponent regressions")
struct BoxComponentRegressionTests {
    @Test("Wide-character titles do not overflow the border")
    func wideTitleFits() {
        let box = BoxComponent(title: "文件差分", child: StaticLines(["body"]))
        for width in 6...40 {
            for line in box.render(width: width) {
                #expect(ANSIWidth.visibleWidth(of: line) <= width)
            }
        }
    }

    @Test("Long titles are clipped rather than overflowing")
    func longTitleClipped() {
        let box = BoxComponent(title: "an extremely long dialog title", child: StaticLines(["b"]))
        let top = box.render(width: 20)[0]
        #expect(ANSIWidth.visibleWidth(of: top) == 20)
    }
}

@Suite("TranscriptList regressions")
struct TranscriptListRegressionTests {
    @Test("Preview commit is written back to the message array")
    func previewCommitSyncs() {
        // `commitStreaming()` clears `isStreaming` on the view's value copy only; without
        // the write-back `activeStreamingView()` keeps returning the finished message and
        // the next turn's tokens land on the previous reply.
        let list = TranscriptListComponent()
        TUIStreamingSurfaceSinkLogic.sendTokenDelta("first", to: list)
        TUIStreamingSurfaceSinkLogic.commitPreview(to: list)
        #expect(list.messages.last?.isStreaming == false)

        TUIStreamingSurfaceSinkLogic.sendTokenDelta("second", to: list)
        #expect(list.messages.count == 2)
        #expect(list.messages[0].content.contains("first"))
    }

    @Test("Height table is cached rather than re-rendered every frame")
    func heightsAreCached() {
        let list = TranscriptListComponent(viewportRows: 4, marginRows: 0)
        let stable = TUIMessage(role: .user, content: "stable content")
        list.appendMessage(stable)
        for _ in 0..<5 { _ = list.render(width: 30) }
        #expect(list.view(for: stable).renderCount == 1)
    }

    @Test("Cached views are bounded")
    func cacheIsBounded() {
        let list = TranscriptListComponent(viewportRows: 4, marginRows: 0, maximumCachedViews: 10)
        for index in 0..<50 {
            list.appendMessage(TUIMessage(role: .user, content: "m\(index)"))
            _ = list.render(width: 30)
        }
        #expect(list.messages.count == 50)
        // Still renders correctly with a pruned cache.
        #expect(!list.render(width: 30).isEmpty)
    }
}

// MARK: - Fixtures

private final class StaticLines: TUIComponent {
    var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width, ellipsis: "")) }
    }
}

private final class CountingLines: TUIComponent {
    var lines: [String]
    private(set) var renderCount = 0
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        renderCount += 1
        return lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width, ellipsis: "")) }
    }
}

private final class FocusableLines: TUIComponent, Focusable {
    var lines: [String]
    var isFocused: Bool = false
    private(set) var received: [String] = []
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width, ellipsis: "")) }
    }
    func handleInput(_ data: String) { received.append(data) }
}

private final class RecordingComponent: TUIComponent {
    private(set) var received: [String] = []
    func render(width: Int) -> [String] { [ANSIStyle.finishLine("")] }
    func handleInput(_ data: String) { received.append(data) }
}

private final class BoolBox {
    private(set) var value = false
    func set() { value = true }
}
