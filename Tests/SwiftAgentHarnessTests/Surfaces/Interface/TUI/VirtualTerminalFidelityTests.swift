import Foundation
import Testing
@testable import SwiftAgentHarness

/// The headless emulator is the oracle every renderer and component test asserts
/// against. Where it diverges from a real TTY it does not merely fail to catch bugs —
/// it actively certifies them. These tests pin the divergences that mattered.
@Suite("VirtualTerminal fidelity")
struct VirtualTerminalFidelityTests {
    @Test("LF does not imply a carriage return")
    func lineFeedDoesNotReturn() {
        // ProcessTerminal clears OPOST, so ONLCR is off: a bare LF moves down only.
        let term = VirtualTerminal(columns: 20, rows: 5)
        term.write("abc")
        term.write("\n")
        term.write("X")
        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("abc"))
        #expect(lines[1].hasPrefix("   X"))
    }

    @Test("CRLF returns to column zero")
    func carriageReturnLineFeed() {
        let term = VirtualTerminal(columns: 20, rows: 5)
        term.write("abc")
        term.write("\r\n")
        term.write("X")
        #expect(term.frameLines()[1].hasPrefix("X"))
    }

    @Test("ESC[J erases to end of display, not end of line")
    func eraseInDisplayClearsBelow() {
        let term = VirtualTerminal(columns: 10, rows: 4)
        term.write("AAAA\r\nBBBB\r\nCCCC")
        term.write(TUIEscapes.moveUp(1))
        term.write("\r")
        term.clearFromCursor()
        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("AAAA"))
        #expect(lines[1].trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(lines[2].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("Writing past the last column wraps to the next row")
    func autowrap() {
        let term = VirtualTerminal(columns: 4, rows: 4)
        term.write("abcdef")
        let lines = term.frameLines()
        #expect(lines[0].hasPrefix("abcd"))
        #expect(lines[1].hasPrefix("ef"))
    }

    @Test("Wide characters occupy two cells but appear once")
    func wideCharacterCells() {
        let term = VirtualTerminal(columns: 6, rows: 2)
        term.write("日本")
        let line = term.frameLine(0)
        #expect(line.hasPrefix("日本"))
        #expect(ANSIWidth.visibleWidth(of: line) == 6)
    }

    @Test("SGR extended colour is parsed positionally")
    func extendedColourSelector() {
        // `CSI 1;38;5;39m` is bold plus colour 39 — reading params[2] absolutely yields 5.
        let term = VirtualTerminal(columns: 10, rows: 2)
        term.write(ANSIStyle.styled("x", fg: 39, bold: true))
        let style = term.styleAt(row: 0, column: 0)
        #expect(style?.fg == 39)
        #expect(style?.bold == true)
    }

    @Test("SGR state persists across separate writes")
    func stylePersistsAcrossWrites() {
        // The renderer emits one write per line; a per-call style reset makes cross-line
        // bleed structurally undetectable.
        let term = VirtualTerminal(columns: 10, rows: 3)
        term.write(TUIEscapes.sgr(bold: true))
        term.write("a")
        #expect(term.styleAt(row: 0, column: 0)?.bold == true)
        term.write(TUIEscapes.styleReset)
        term.write("b")
        #expect(term.styleAt(row: 0, column: 1)?.bold == false)
    }

    @Test("Scrolled rows are captured in scrollback")
    func scrollbackCaptured() {
        let term = VirtualTerminal(columns: 10, rows: 2)
        term.write("one\r\ntwo\r\nthree")
        #expect(term.scrollbackLines().first?.hasPrefix("one") == true)
    }

    @Test("Synchronized update markers balance")
    func synchronizedDepthBalances() {
        let term = VirtualTerminal(columns: 20, rows: 4)
        let renderer = DifferentialRenderer(terminal: term)
        renderer.renderLines(["a"], width: 20)
        renderer.renderLines(["b"], width: 20)
        #expect(term.synchronizedUpdateDepth == 0)
    }

    @Test("ESC[2K does not move the cursor")
    func eraseLineKeepsCursor() {
        let term = VirtualTerminal(columns: 10, rows: 2)
        term.write("abcdef")
        let before = term.cursorColumn
        term.write(TUIEscapes.clearLine)
        #expect(term.cursorColumn == before)
    }

    @Test("Resize preserves content and notifies without deadlocking")
    func resizeNotifies() {
        let term = VirtualTerminal(columns: 10, rows: 3)
        term.write("keep")
        let observed = ResizeRecorder()
        term.start(onInput: { _ in }, onResize: { columns, rows in
            observed.record(columns: columns, rows: rows)
        })
        term.resize(columns: 20, rows: 6)
        #expect(term.columns == 20)
        #expect(term.frameLines()[0].hasPrefix("keep"))
        #expect(observed.latest?.0 == 20)
        #expect(observed.latest?.1 == 6)
    }

    @Test("simulateInput reaches the registered handler")
    func simulateInputDelivers() {
        let term = VirtualTerminal(columns: 10, rows: 3)
        let recorder = InputRecorder()
        term.start(onInput: { recorder.record($0) }, onResize: { _, _ in })
        term.simulateInput("hi")
        #expect(recorder.received == ["hi"])
    }
}

final class ResizeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, Int)?
    var latest: (Int, Int)? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func record(columns: Int, rows: Int) {
        lock.lock(); value = (columns, rows); lock.unlock()
    }
}

final class InputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var received: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    func record(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }
}
