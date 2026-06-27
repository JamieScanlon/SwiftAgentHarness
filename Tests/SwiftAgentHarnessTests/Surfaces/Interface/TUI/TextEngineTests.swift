import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ANSIWidth")
struct ANSIWidthTests {
    @Test("Counts visible width ignoring ANSI")
    func visibleWidthIgnoresANSI() {
        let text = ANSIStyle.bold("hello")
        #expect(ANSIWidth.visibleWidth(of: text) == 5)
    }

    @Test("Wide characters count as two columns")
    func wideCharacters() {
        #expect(ANSIWidth.visibleWidth(of: "日本") == 4)
    }

    @Test("Strips ANSI for plain text")
    func stripANSI() {
        #expect(ANSIWidth.stripANSI(ANSIStyle.color("x", fg: 1)) == "x")
    }
}

@Suite("ANSITruncate")
struct ANSITruncateTests {
    @Test("Truncates preserving escapes")
    func truncateStyled() {
        let input = ANSIStyle.bold("hello world")
        let truncated = ANSITruncate.truncate(input, toWidth: 8)
        #expect(ANSIWidth.visibleWidth(of: truncated) <= 8)
    }
}

@Suite("ANSIWrap")
struct ANSIWrapTests {
    @Test("Wraps long text to width")
    func wraps() {
        let lines = ANSIWrap.wrap("one two three four five", width: 10)
        #expect(lines.count >= 2)
        for line in lines {
            #expect(ANSIWidth.visibleWidth(of: line) <= 10)
        }
    }
}

@Suite("ANSIStyle")
struct ANSIStyleTests {
    @Test("Appends per-line reset suffix")
    func finishLine() {
        let line = ANSIStyle.finishLine(ANSIStyle.bold("hi"))
        #expect(line.hasSuffix(ANSIStyle.lineResetSuffix))
    }
}

@Suite("CursorMarker")
struct CursorMarkerTests {
    @Test("Inserts and locates marker")
    func insertAndLocate() {
        let line = CursorMarker.insert(into: "hello", atVisibleColumn: 3)
        let location = CursorMarker.locate(in: [line])
        #expect(location?.row == 0)
        #expect(location?.column == 3)
        #expect(ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) == 5)
    }
}
