import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("BlockChunker")
struct BlockChunkerTests {
    @Test("Does not emit until minChars unless flushing")
    func minCharsBound() {
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 50, maxChars: 200, textChunkLimit: 200),
            breakPreference: .paragraph
        )
        let early = chunker.ingest("Short text.")
        #expect(early.isEmpty)
        let flushed = chunker.flush()
        #expect(flushed == ["Short text."])
    }

    @Test("Prefers paragraph break before maxChars")
    func paragraphBreak() {
        let para1 = String(repeating: "a", count: 30)
        let para2 = String(repeating: "b", count: 30)
        let text = para1 + "\n\n" + para2 + "\n\n" + String(repeating: "c", count: 30)
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 20, maxChars: 200, textChunkLimit: 200),
            breakPreference: .paragraph
        )
        let chunks = chunker.ingest(text)
        #expect(chunks.count >= 1)
        #expect(chunks[0].hasSuffix(para2) || chunks[0].contains("\n\n"))
    }

    @Test("Clamps maxChars to textChunkLimit")
    func textChunkLimitClamp() {
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 10, maxChars: 500, textChunkLimit: 80),
            breakPreference: .hard
        )
        let text = String(repeating: "x", count: 200)
        let chunks = chunker.ingest(text) + chunker.flush()
        for chunk in chunks {
            #expect(chunk.count <= 80)
        }
    }

    @Test("Closes and reopens code fence on forced hard split")
    func codeFenceHardSplit() {
        let codeBody = String(repeating: "x", count: 120)
        let text = "```swift\n" + codeBody
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 10, maxChars: 60, textChunkLimit: 60),
            breakPreference: .hard
        )
        let chunks = chunker.ingest(text) + chunker.flush()
        #expect(chunks.count >= 2)
        #expect(chunks[0].hasSuffix("```"))
        #expect(chunks[1].hasPrefix("```swift\n") || chunks[1].hasPrefix("```\n"))
    }

    @Test("Never splits at break inside code fence")
    func noBreakInsideFence() {
        let prose = String(repeating: "word ", count: 15)
        let fenced = "\n\n```\nline one\n\nline two\n```\n\n"
        let tail = String(repeating: "z", count: 40)
        let text = prose + fenced + tail
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 30, maxChars: 200, textChunkLimit: 200),
            breakPreference: .paragraph
        )
        let chunks = chunker.ingest(text) + chunker.flush()
        for chunk in chunks {
            let opens = chunk.components(separatedBy: "```").count - 1
            #expect(opens % 2 == 0, "Unbalanced fences in chunk: \(chunk)")
        }
    }

    @Test("maxLines soft cap splits tall replies")
    func maxLinesCap() {
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 5, maxChars: 500, textChunkLimit: 500, maxLines: 5),
            breakPreference: .hard
        )
        let chunks = chunker.ingest(lines) + chunker.flush()
        #expect(chunks.count >= 2)
        #expect(chunks[0].components(separatedBy: "\n").count <= 6)
    }
}
