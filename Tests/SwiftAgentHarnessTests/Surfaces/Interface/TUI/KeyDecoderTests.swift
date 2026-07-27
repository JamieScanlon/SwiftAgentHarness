import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TUIKeyDecoder")
struct TUIKeyDecoderTests {
    @Test("Coalesced typing followed by Enter still submits")
    func coalescedEnter() {
        // One read routinely carries several keystrokes. Comparing the whole buffer to
        // "\r" matched nothing here, so the text was inserted with a literal CR and the
        // turn was never submitted.
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("abc\r") == [.text("abc"), .enter])
    }

    @Test("Plain text decodes as one run")
    func plainText() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("hello") == [.text("hello")])
    }

    @Test("Control keys decode individually")
    func controlKeys() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{03}") == [.interrupt])
        #expect(decoder.decode("\u{04}") == [.endOfTransmission])
        #expect(decoder.decode("\u{09}") == [.tab])
        #expect(decoder.decode("\u{7F}") == [.backspace])
        #expect(decoder.decode("\n") == [.newline])
    }

    @Test("Arrow keys decode from CSI sequences")
    func arrows() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}[A") == [.up])
        #expect(decoder.decode("\u{1B}[B") == [.down])
        #expect(decoder.decode("\u{1B}[C") == [.right])
        #expect(decoder.decode("\u{1B}[D") == [.left])
        #expect(decoder.decode("\u{1B}[Z") == [.backTab])
    }

    @Test("Tilde-terminated sequences decode")
    func tildeSequences() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}[3~") == [.delete])
        #expect(decoder.decode("\u{1B}[5~") == [.pageUp])
        #expect(decoder.decode("\u{1B}[6~") == [.pageDown])
    }

    @Test("Escape sequences split across reads reassemble")
    func splitEscapeSequence() {
        // The paste accumulator only holds back partial paste-start markers, so a split
        // arrow used to arrive as a lone ESC that got typed into the buffer as text.
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}[") == [])
        #expect(decoder.decode("A") == [.up])
    }

    @Test("A lone ESC is the Escape key")
    func loneEscape() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}") == [.escape])
    }

    @Test("Alt-Enter inserts a line break")
    func altEnter() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}\r") == [.newline])
    }

    @Test("A complete paste envelope decodes as one paste key")
    func pasteEnvelope() {
        var decoder = TUIKeyDecoder()
        let envelope = BracketedPaste.start + "a\nb" + BracketedPaste.end
        guard case let .paste(result)? = decoder.decode(envelope).first else {
            Issue.record("Expected a paste key")
            return
        }
        #expect(result.text == "a\nb")
        #expect(result.lineCount == 2)
    }

    @Test("Ordering is preserved across mixed input")
    func mixedOrdering() {
        var decoder = TUIKeyDecoder()
        let keys = decoder.decode("ab\u{1B}[Dcd\r")
        #expect(keys == [.text("ab"), .left, .text("cd"), .enter])
    }

    @Test("flush releases a held partial sequence")
    func flushReleasesPending() {
        var decoder = TUIKeyDecoder()
        #expect(decoder.decode("\u{1B}[") == [])
        let flushed = decoder.flush()
        #expect(flushed.count == 1)
        if case .unhandled = flushed[0] {} else { Issue.record("Expected unhandled") }
    }

    @Test("Unknown control bytes are dropped, not typed")
    func unknownControlDropped() {
        var decoder = TUIKeyDecoder()
        let keys = decoder.decode("a\u{01}b")
        #expect(keys == [.text("a"), .unhandled("\u{01}"), .text("b")])
    }
}
