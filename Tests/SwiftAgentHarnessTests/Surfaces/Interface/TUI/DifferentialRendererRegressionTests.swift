import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("DifferentialRenderer regressions")
struct DifferentialRendererRegressionTests {
    @Test("Shrinking frame erases the rows it dropped")
    func shrinkClearsStaleRows() {
        // `fromLine >= frame.count` used to fail the guard, so `apply` wrote nothing at
        // all: the dropped row stayed on screen and `lastFrame` was updated anyway, so
        // the diff never noticed again.
        let term = VirtualTerminal(columns: 20, rows: 5)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["A", "B", "C"], width: 20)
        renderer.renderLines(["A", "B"], width: 20)

        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("A"))
        #expect(lines[1].hasPrefix("B"))
        #expect(lines[2].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("Cursor accounting survives a shrink")
    func shrinkKeepsCursorAccounting() {
        let term = VirtualTerminal(columns: 20, rows: 5)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["A", "B", "C"], width: 20)
        renderer.renderLines(["A", "B"], width: 20)
        renderer.renderLines(["A", "B2"], width: 20)

        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("A"))
        #expect(lines[1].hasPrefix("B2"))
        #expect(lines[2].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("Growing frame at the screen bottom scrolls instead of overwriting")
    func growAtBottomScrolls() {
        // `CSI B` clamps at the bottom margin and cannot scroll, so moving "down" one row
        // from the last row was a no-op — and the following clear-and-write destroyed the
        // frame's own last line.
        let term = VirtualTerminal(columns: 20, rows: 2)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["A", "B"], width: 20)
        renderer.renderLines(["A", "B", "C"], width: 20)

        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("B"))
        #expect(lines[1].hasPrefix("C"))
        #expect(term.scrollbackLines().last?.hasPrefix("A") == true)
    }

    @Test("Identical frame repaints nothing")
    func identicalFrameIsNoOp() {
        let term = VirtualTerminal(columns: 20, rows: 5)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["alpha", "beta"], width: 20)
        term.clearRawOutput()
        renderer.renderLines(["alpha", "beta"], width: 20)
        #expect(!term.rawOutput.contains("alpha"))
        #expect(!term.rawOutput.contains("beta"))
        #expect(!term.rawOutput.contains(TUIEscapes.clearScreen))
    }

    @Test("Change above the viewport forces a full clear")
    func changeAboveViewportFullClears() {
        // Computed from the frame geometry, not taken on trust from the caller — the
        // caller cannot see where the viewport falls.
        let term = VirtualTerminal(columns: 20, rows: 3)
        let renderer = DifferentialRenderer(terminal: term)
        let first = (0..<6).map { "row \($0)" }
        renderer.renderLines(first, width: 20)
        term.clearRawOutput()
        var second = first
        second[0] = "row CHANGED"
        renderer.renderLines(second, width: 20)
        #expect(term.rawOutput.contains(TUIEscapes.clearScreen))
    }

    @Test("Lines are separated by CRLF, never a bare LF")
    func writesCarriageReturnLineFeed() {
        // With OPOST cleared a bare LF does not return to column 0, so every line after
        // the first starts where the previous one ended — the frame staircases.
        let term = VirtualTerminal(columns: 20, rows: 5)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["first", "second", "third"], width: 20)

        var sawBareLineFeed = false
        var previous: Character?
        for character in term.rawOutput {
            if character == "\n", previous != "\r" { sawBareLineFeed = true }
            previous = character
        }
        #expect(!sawBareLineFeed)

        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("first"))
        #expect(lines[1].hasPrefix("second"))
        #expect(lines[2].hasPrefix("third"))
    }

    @Test("Frame is not staircased on a raw-mode terminal")
    func noStaircase() {
        let term = VirtualTerminal(columns: 30, rows: 6)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["aaa", "bbb", "ccc"], width: 30)
        let lines = term.frameLines()
        for line in lines.prefix(3) {
            #expect(!line.hasPrefix(" "))
        }
    }

    @Test("Renderer reset restores first-render behaviour")
    func resetRestoresFirstRender() {
        let term = VirtualTerminal(columns: 20, rows: 5)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["a"], width: 20)
        renderer.reset()
        term.clearRawOutput()
        renderer.renderLines(["a"], width: 20)
        #expect(term.rawOutput.contains("a"))
        #expect(!term.rawOutput.contains(TUIEscapes.clearScreen))
    }
}
