import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ANSIWidth regressions")
struct ANSIWidthRegressionTests {
    @Test("Emoji occupy two columns")
    func emojiWidth() {
        #expect(ANSIWidth.characterWidth("\u{1F600}") == 2)
        #expect(ANSIWidth.visibleWidth(of: "a\u{1F600}b") == 4)
    }

    @Test("ZWJ sequences are a single double-width cluster")
    func zwjSequenceWidth() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(family.count == 1)
        #expect(ANSIWidth.visibleWidth(of: family) == 2)
    }

    @Test("Regional-indicator flags are two columns")
    func flagWidth() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        #expect(ANSIWidth.visibleWidth(of: flag) == 2)
    }

    @Test("Variation selector 16 promotes a symbol to emoji width")
    func variationSelectorWidth() {
        #expect(ANSIWidth.visibleWidth(of: "\u{2764}\u{FE0F}") == 2)
    }

    @Test("Standalone combining marks are zero width")
    func combiningMarkWidth() {
        #expect(ANSIWidth.characterWidth("\u{0301}") == 0)
        // Attached to a base character it forms one cluster of width one.
        #expect(ANSIWidth.visibleWidth(of: "e\u{0301}") == 1)
    }

    @Test("CSI sequences ending in tilde terminate correctly")
    func csiTildeTerminates() {
        // `isLetter` never terminates `ESC[200~`, so the scanner ran on and swallowed
        // real text — under-measuring the line and letting the real terminal wrap it.
        #expect(ANSIWidth.visibleWidth(of: "\u{1B}[200~hello") == 5)
        #expect(ANSIWidth.visibleWidth(of: "\u{1B}[3~x") == 1)
    }

    @Test("OSC-8 hyperlink URLs containing m are skipped whole")
    func hyperlinkWithLetterM() {
        let link = TUIEscapes.hyperlink("https://example.com/main", label: "x")
        #expect(ANSIWidth.visibleWidth(of: link) == 1)
    }

    @Test("APC cursor marker measures as zero width")
    func cursorMarkerZeroWidth() {
        #expect(ANSIWidth.visibleWidth(of: CursorMarker.sentinel) == 0)
    }
}

@Suite("ANSITruncate regressions")
struct ANSITruncateRegressionTests {
    @Test("Cursor marker keeps its column through truncation")
    func markerKeepsPosition() {
        // Buffering the marker with pending style escapes and flushing after the ellipsis
        // pinned the hardware cursor — and the IME candidate window — to the right edge.
        let line = CursorMarker.insert(into: "abcdefghij", atVisibleColumn: 2)
        let truncated = ANSITruncate.truncate(line, toWidth: 6)
        #expect(CursorMarker.locate(in: [truncated])?.column == 2)
        #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: truncated)) <= 6)
    }

    @Test("Marker beyond the cut is dropped rather than relocated")
    func markerBeyondCutDropped() {
        let line = CursorMarker.insert(into: "abcdefghij", atVisibleColumn: 9)
        let truncated = ANSITruncate.truncate(line, toWidth: 5)
        #expect(CursorMarker.locate(in: [truncated]) == nil)
    }

    @Test("fit pads short lines to exactly the requested width")
    func fitPads() {
        let padded = ANSITruncate.fit("ab", toWidth: 6, ellipsis: "")
        #expect(ANSIWidth.visibleWidth(of: padded) == 6)
    }

    @Test("fit clips long lines to exactly the requested width")
    func fitClips() {
        let clipped = ANSITruncate.fit("abcdefghij", toWidth: 4)
        #expect(ANSIWidth.visibleWidth(of: clipped) == 4)
    }
}

@Suite("ANSIWrap regressions")
struct ANSIWrapRegressionTests {
    @Test("Styled text whose segment ends in m does not duplicate")
    func styledWrapDoesNotDuplicate() {
        // `extractTrailingStyle` used to slice from the last ESC to end-of-line and return
        // it whenever that slice ended in `m` — which is true for `algorithm`, `problem`,
        // `system`, `stream`… so the whole segment was prepended to the next line.
        let lines = ANSIWrap.wrap(ANSIStyle.dim("aaa bbb algorithm ccc"), width: 17)
        for line in lines {
            #expect(ANSIWidth.visibleWidth(of: line) <= 17)
        }
        let visible = lines.map { ANSIWidth.stripANSI($0) }.joined(separator: " ")
        #expect(visible.components(separatedBy: "algorithm").count == 2)
    }

    @Test("Styled wrapping never exceeds the width bound")
    func styledWrapRespectsWidth() {
        let samples = [
            "hello there problem xyz tail",
            "one system two stream three confirm",
            "plain words with no trap at all",
        ]
        for sample in samples {
            for width in [8, 12, 17, 20, 40] {
                for line in ANSIWrap.wrap(ANSIStyle.dim(sample), width: width) {
                    #expect(ANSIWidth.visibleWidth(of: line) <= width)
                }
            }
        }
    }

    @Test("Style prefix does not become a leading space")
    func noSpuriousLeadingSpace() {
        let lines = ANSIWrap.wrap(ANSIStyle.dim("alpha beta gamma delta"), width: 11)
        for line in lines {
            #expect(!ANSIWidth.stripANSI(line).hasPrefix(" "))
        }
    }
}

@Suite("CursorMarker regressions")
struct CursorMarkerRegressionTests {
    @Test("Non-m CSI sequences do not swallow the rest of the line")
    func csiDoesNotSwallowLine() {
        // The bespoke state machine only exited escape mode on `m`, `\` or BEL, so a
        // `CSI 2K` left it consuming the remainder and pinned the marker to end of line.
        let line = "\u{1B}[2Kabcdef"
        let marked = CursorMarker.insert(into: line, atVisibleColumn: 3)
        #expect(CursorMarker.locate(in: [marked])?.column == 3)
    }

    @Test("Hyperlink URLs containing m do not end escape scanning early")
    func hyperlinkDoesNotEndEarly() {
        let line = TUIEscapes.hyperlink("https://example.com/main", label: "abcdef")
        let marked = CursorMarker.insert(into: line, atVisibleColumn: 2)
        #expect(CursorMarker.locate(in: [marked])?.column == 2)
    }

    @Test("Marker placement respects wide characters")
    func wideCharacterColumns() {
        let marked = CursorMarker.insert(into: "日本語", atVisibleColumn: 4)
        #expect(CursorMarker.locate(in: [marked])?.column == 4)
    }
}

@Suite("TUITextSanitizer")
struct TUITextSanitizerTests {
    @Test("Strips escape sequences from untrusted text")
    func stripsEscapes() {
        let hostile = "safe\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{7}end"
        #expect(TUITextSanitizer.sanitizeMultiline(hostile) == "saferedend")
    }

    @Test("Strips control characters but keeps newlines and tabs")
    func stripsControls() {
        let input = "a\u{03}b\tc\nd\u{7F}e"
        #expect(TUITextSanitizer.sanitizeMultiline(input) == "ab\tc\nde")
    }

    @Test("Normalizes carriage returns to newlines")
    func normalizesCarriageReturns() {
        #expect(TUITextSanitizer.sanitizeMultiline("a\r\nb\rc") == "a\nb\nc")
    }

    @Test("Single-line mode drops newlines")
    func singleLineDropsNewlines() {
        #expect(TUITextSanitizer.sanitizeSingleLine("a\nb") == "ab")
    }

    @Test("Removes injected cursor markers")
    func removesCursorMarker() {
        let hostile = "before" + CursorMarker.sentinel + "after"
        #expect(TUITextSanitizer.sanitizeMultiline(hostile) == "beforeafter")
    }
}
