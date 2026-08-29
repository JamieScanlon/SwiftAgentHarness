import Foundation
import Testing
@testable import SwiftAgentHarness

#if os(macOS)
@Suite("ProcessTerminal input decoding")
struct ProcessTerminalInputTests {
    @Test("A complete buffer is decoded whole")
    func completeBuffer() {
        let bytes = Array("hello".utf8)
        let (complete, partial) = ProcessTerminal.splitTrailingPartialUTF8(bytes)
        #expect(complete == bytes)
        #expect(partial.isEmpty)
    }

    @Test("A trailing partial multi-byte sequence is held back")
    func heldPartialSequence() {
        // Decoding each read independently replaced a code point straddling the read
        // boundary with U+FFFD — corrupting exactly the CJK and emoji input the IME
        // support exists for.
        let full = Array("あ".utf8)
        #expect(full.count == 3)
        let truncated = Array(full.prefix(2))
        let (complete, partial) = ProcessTerminal.splitTrailingPartialUTF8(truncated)
        #expect(complete.isEmpty)
        #expect(partial == truncated)
    }

    @Test("Held bytes complete on the next read")
    func partialCompletes() {
        let full = Array("日本語".utf8)
        let boundary = 4
        let first = Array(full.prefix(boundary))
        let second = Array(full.dropFirst(boundary))

        let (firstComplete, firstPartial) = ProcessTerminal.splitTrailingPartialUTF8(first)
        let (secondComplete, secondPartial) = ProcessTerminal.splitTrailingPartialUTF8(firstPartial + second)

        #expect(secondPartial.isEmpty)
        let decoded = String(decoding: firstComplete + secondComplete, as: UTF8.self)
        #expect(decoded == "日本語")
        #expect(!decoded.contains("\u{FFFD}"))
    }

    @Test("A four-byte emoji split at every offset round-trips")
    func emojiSplits() {
        let full = Array("\u{1F600}".utf8)
        #expect(full.count == 4)
        for boundary in 1..<full.count {
            let (firstComplete, firstPartial) = ProcessTerminal.splitTrailingPartialUTF8(Array(full.prefix(boundary)))
            let (secondComplete, secondPartial) = ProcessTerminal.splitTrailingPartialUTF8(
                firstPartial + Array(full.dropFirst(boundary))
            )
            #expect(secondPartial.isEmpty)
            #expect(String(decoding: firstComplete + secondComplete, as: UTF8.self) == "\u{1F600}")
        }
    }

    @Test("Invalid lead bytes are passed through rather than held forever")
    func invalidLeadPassesThrough() {
        let bytes: [UInt8] = [0xFF, 0xFE]
        let (complete, partial) = ProcessTerminal.splitTrailingPartialUTF8(bytes)
        #expect(complete == bytes)
        #expect(partial.isEmpty)
    }

    @Test("An empty read decodes to nothing")
    func emptyBuffer() {
        let (complete, partial) = ProcessTerminal.splitTrailingPartialUTF8([])
        #expect(complete.isEmpty)
        #expect(partial.isEmpty)
    }
}
#endif
