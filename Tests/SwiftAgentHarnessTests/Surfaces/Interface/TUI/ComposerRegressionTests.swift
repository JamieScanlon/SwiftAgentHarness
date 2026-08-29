import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("InputComposer paste regressions")
struct InputComposerPasteRegressionTests {
    private func paste(_ inner: String) -> String {
        BracketedPaste.start + inner + BracketedPaste.end
    }

    @Test("Two-line paste keeps both lines")
    func twoLinePaste() {
        // The previous splice wiped the paste's first line and any pre-existing buffer:
        // "" + "a\nb" produced ["b"].
        let composer = InputComposerComponent()
        composer.handleInput(paste("a\nb"))
        #expect(composer.lines == ["a", "b"])
        #expect(composer.text == "a\nb")
    }

    @Test("Three-line paste keeps every line")
    func threeLinePaste() {
        let composer = InputComposerComponent()
        composer.handleInput(paste("a\nb\nc"))
        #expect(composer.lines == ["a", "b", "c"])
    }

    @Test("Four-line paste does not merge or lose lines")
    func fourLinePaste() {
        let composer = InputComposerComponent()
        composer.handleInput(paste("one\ntwo\nthree\nfour"))
        #expect(composer.lines == ["one", "two", "three", "four"])
    }

    @Test("Paste splices around the cursor and re-attaches the tail")
    func pasteSplicesAroundCursor() {
        let composer = InputComposerComponent(lines: ["prefixsuffix"])
        composer.cursorLine = 0
        composer.cursorColumn = 6
        composer.handleInput(paste("X\nY\nZ"))
        #expect(composer.lines == ["prefixX", "Y", "Zsuffix"])
        #expect(composer.cursorColumn == 1)
        #expect(composer.cursorLine == 2)
    }

    @Test("Backspace after a multi-line paste does not trap")
    func backspaceAfterPasteIsSafe() {
        // The cursor used to land one line past the inserted block with a column from a
        // different line, and `deleteBackward` indexed with it unclamped.
        let composer = InputComposerComponent(lines: ["", "Z"])
        composer.cursorLine = 0
        composer.cursorColumn = 0
        composer.handleInput(paste("a\nb\ncccc"))
        composer.handleInput("\u{7F}")
        #expect(composer.lines == ["a", "b", "ccc", "Z"])
    }

    @Test("Backspace with an out-of-range cursor column is clamped")
    func backspaceClampsColumn() {
        let composer = InputComposerComponent(lines: ["ab"])
        composer.cursorLine = 0
        composer.cursorColumn = 99
        composer.deleteBackward()
        #expect(composer.lines == ["a"])
    }

    @Test("CR-separated paste is normalized and counted")
    func carriageReturnPaste() {
        // Terminals deliver paste newlines as CR; splitting on LF alone reported one
        // line and left literal CRs in the buffer.
        let result = BracketedPaste.unwrap(paste("a\rb\rc"))
        #expect(result?.lineCount == 3)
        #expect(result?.text == "a\nb\nc")

        let composer = InputComposerComponent()
        composer.handleInput(paste("a\rb\rc"))
        #expect(composer.lines == ["a", "b", "c"])
        #expect(!composer.text.contains("\r"))
    }

    @Test("CRLF paste is counted correctly despite grapheme clustering")
    func crlfPasteMetadata() {
        // Swift merges CR+LF into one Character, so a `contains("\r")` guard and a
        // `split(separator: "\n")` both miss it — reporting a 15-line paste as one line
        // and defeating the large-paste threshold.
        let inner = (0..<15).map { "line \($0)" }.joined(separator: "\r\n")
        let result = BracketedPaste.unwrap(paste(inner))
        #expect(result?.lineCount == 15)
        #expect(result?.isLargePaste == true)
        #expect(result?.text.contains("\r") == false)
    }

    @Test("Large pastes collapse to a placeholder but submit in full")
    func largePastePlaceholder() {
        let inner = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let composer = InputComposerComponent()
        composer.handleInput(paste(inner))

        #expect(composer.lines.count == 1)
        #expect(composer.text.contains("Pasted 20 lines"))
        #expect(composer.expandedText.contains("line 19"))
        #expect(composer.makeSubmission().text.contains("line 0"))
        #expect(composer.makeSubmission().text.contains("line 19"))
    }

    @Test("Paste provenance survives subsequent typing")
    func provenanceIsSticky() {
        // Provenance describes the submission; one keystroke after a large paste must not
        // relabel it as typed input, because this feeds the control-input trust decision.
        let composer = InputComposerComponent()
        composer.handleInput(paste((0..<15).map { "l\($0)" }.joined(separator: "\n")))
        composer.handleInput("x")
        let submission = composer.makeSubmission()
        #expect(submission.provenance.wasPasted)
        #expect(submission.provenance.pasteLineCount == 15)
    }

    @Test("clear resets paste provenance and stored blocks")
    func clearResetsProvenance() {
        let composer = InputComposerComponent()
        composer.handleInput(paste("a\nb"))
        composer.clear()
        let submission = composer.makeSubmission()
        #expect(!submission.provenance.wasPasted)
        #expect(submission.provenance.pasteLineCount == 0)
        #expect(submission.text.isEmpty)
    }

    @Test("Pasted escape sequences are sanitized")
    func pasteIsSanitized() {
        let composer = InputComposerComponent()
        composer.handleInput(paste("safe\u{1B}[31mred"))
        #expect(composer.text == "safered")
    }
}

@Suite("InputComposer editing regressions")
struct InputComposerEditingRegressionTests {
    @Test("Control characters never land in the buffer")
    func controlCharactersRejected() {
        // `isASCII` is true for Ctrl-C, Tab and a bare ESC, so they used to be typed in.
        let composer = InputComposerComponent()
        composer.handleInput("a")
        composer.handleInput("\u{03}")
        composer.handleInput("\u{1B}")
        composer.handleInput("b")
        #expect(composer.text == "ab")
    }

    @Test("insertNewline splits the current line at the cursor")
    func newlineSplitsLine() {
        let composer = InputComposerComponent(lines: ["abcd"])
        composer.cursorColumn = 2
        composer.insertNewline()
        #expect(composer.lines == ["ab", "cd"])
        #expect(composer.cursorLine == 1)
        #expect(composer.cursorColumn == 0)
    }

    @Test("Backspace joins lines at a boundary")
    func backspaceJoinsLines() {
        let composer = InputComposerComponent(lines: ["ab", "cd"])
        composer.cursorLine = 1
        composer.cursorColumn = 0
        composer.deleteBackward()
        #expect(composer.lines == ["abcd"])
        #expect(composer.cursorLine == 0)
        #expect(composer.cursorColumn == 2)
    }

    @Test("Placeholder renders when the composer is empty and focused")
    func placeholderWhenFocused() {
        // The placeholder branch used to require `!isFocused`, which never holds.
        let composer = InputComposerComponent(placeholder: "Type here")
        composer.isFocused = true
        let rendered = composer.render(width: 40).joined()
        #expect(rendered.contains("Type here"))
        #expect(rendered.contains(CursorMarker.sentinel))
    }

    @Test("Wide characters keep the cursor column in display units")
    func wideCharacterCursorColumn() {
        let composer = InputComposerComponent(lines: ["日本"])
        composer.isFocused = true
        composer.cursorLine = 0
        composer.cursorColumn = 1
        let line = composer.render(width: 40)[0]
        // Prompt is two columns; one wide character is two more.
        #expect(CursorMarker.locate(in: [line])?.column == 4)
    }

    @Test("Multi-line buffer renders one line per row within the width bound")
    func multiLineRender() {
        let composer = InputComposerComponent(lines: ["one", "two", "three"])
        let lines = composer.render(width: 20)
        #expect(lines.count == 3)
        for line in lines {
            #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) <= 20)
        }
    }
}
