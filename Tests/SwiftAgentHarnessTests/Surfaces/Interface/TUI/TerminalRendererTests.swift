import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("VirtualTerminal")
struct VirtualTerminalTests {
    @Test("Writes text to grid")
    func writesText() {
        let term = VirtualTerminal(columns: 20, rows: 5)
        term.write("hello")
        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("hello"))
    }

    @Test("Handles cursor movement and clear")
    func cursorAndClear() {
        let term = VirtualTerminal(columns: 10, rows: 3)
        term.write("abcdefghij")
        term.write("\n")
        term.write("0123456789")
        term.write(TUIEscapes.moveUp(1))
        term.clearFromCursor()
        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("abcd"))
    }

    @Test("Resize resets grid")
    func resize() {
        let term = VirtualTerminal(columns: 10, rows: 3)
        term.write("test")
        term.resize(columns: 30, rows: 10)
        #expect(term.columns == 30)
        #expect(term.rows == 10)
    }
}

@Suite("DifferentialRenderer")
struct DifferentialRendererTests {
    @Test("First render does not clear scrollback")
    func firstRender() async {
        let term = VirtualTerminal(columns: 40, rows: 10)
        let renderer = DifferentialRenderer(terminal: term)
        let component = StaticLinesComponent(lines: ["line one", "line two"])
        renderer.render(component: component, width: 40, context: "test")
        #expect(term.rawOutput.contains(TUIEscapes.syncStart))
        #expect(!term.rawOutput.contains(TUIEscapes.clearScreen))
    }

    @Test("Width change triggers full clear")
    func widthChange() async {
        let term = VirtualTerminal(columns: 40, rows: 10)
        let renderer = DifferentialRenderer(terminal: term)
        let component = StaticLinesComponent(lines: ["alpha"])
        renderer.render(component: component, width: 40, context: "test")
        term.clearRawOutput()
        renderer.render(component: component, width: 30, context: "test")
        #expect(term.rawOutput.contains(TUIEscapes.clearScreen))
    }

    @Test("Normal update diffs from first changed line")
    func differentialUpdate() async {
        let term = VirtualTerminal(columns: 40, rows: 10)
        let renderer = DifferentialRenderer(terminal: term)
        let component = StaticLinesComponent(lines: ["one", "two"])
        renderer.render(component: component, width: 40, context: "test")
        term.clearRawOutput()
        component.lines = ["one", "two changed"]
        renderer.render(component: component, width: 40, context: "test")
        #expect(term.rawOutput.contains(TUIEscapes.syncStart))
        #expect(term.rawOutput.contains("two changed"))
        #expect(!term.rawOutput.contains(TUIEscapes.clearScreen))
    }

    @Test("Positions hardware cursor at marker")
    func hardwareCursor() async {
        let term = VirtualTerminal(columns: 40, rows: 10)
        let renderer = DifferentialRenderer(terminal: term)
        let composer = InputComposerComponent(lines: ["hi"])
        composer.isFocused = true
        renderer.render(component: composer, width: 40, context: "composer")
        #expect(term.rawOutput.contains(TUIEscapes.showCursor))
        #expect(!term.rawOutput.contains(CursorMarker.sentinel))
    }

    @Test("Differential update targets correct rows under existing scrollback")
    func differentialUnderScrollback() {
        let term = VirtualTerminal(columns: 40, rows: 10)
        term.write("\n\n\n")
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["A", "B", "C"], width: 40)
        renderer.renderLines(["A", "B", "C2"], width: 40)
        let grid = term.frameLines()
        #expect(grid[3].contains("A"))
        #expect(grid[4].contains("B"))
        #expect(grid[5].contains("C2"))
        #expect(!grid[2].contains("C2"))
    }

    @Test("Hardware cursor honors frame start row under scrollback")
    func hardwareCursorUnderScrollback() {
        let term = VirtualTerminal(columns: 40, rows: 10)
        let frameStartRow = 3
        term.write(String(repeating: "\n", count: frameStartRow))
        let renderer = DifferentialRenderer(terminal: term)
        let composer = InputComposerComponent(lines: ["hi"])
        composer.isFocused = true
        composer.cursorLine = 0
        renderer.render(component: composer, width: 40, context: "composer")
        #expect(term.cursorRow == frameStartRow + composer.cursorLine)
    }
}

private final class StaticLinesComponent: TUIComponent {
    var lines: [String]
    init(lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        lines.map { ANSIStyle.finishLine(ANSITruncate.truncate($0, toWidth: width)) }
    }
}
