import Foundation
import os
import Testing
@testable import SwiftAgentHarness

private final class TestStreamingClock: StreamingClock, @unchecked Sendable {
    private let epoch = ContinuousClock.now
    private let elapsedMs = OSAllocatedUnfairLock(initialState: Int64(0))

    func now() -> ContinuousClock.Instant {
        let ms = elapsedMs.withLock { $0 }
        return epoch + .milliseconds(Int(ms))
    }

    func advance(byMilliseconds ms: Int) {
        elapsedMs.withLock { $0 += Int64(ms) }
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        let targetDuration = deadline - epoch
        let components = targetDuration.components
        let ms = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        elapsedMs.withLock { $0 = ms }
    }
}

@Suite("BlockCoalescer")
struct BlockCoalescerTests {
    @Test("Disabled coalescer passes blocks through immediately")
    func disabledPassthrough() async {
        let coalescer = BlockCoalescer(
            config: CoalescingConfig(enabled: false, idleMs: 500, minChars: 100),
            maxChars: 2000,
            breakPreference: .paragraph
        )
        let out = await coalescer.ingest("hello")
        #expect(out == ["hello"])
    }

    @Test("Merges blocks after idle gap")
    func idleGapMerge() async {
        let clock = TestStreamingClock()
        let coalescer = BlockCoalescer(
            config: CoalescingConfig(enabled: true, idleMs: 500, minChars: 5),
            maxChars: 2000,
            breakPreference: .paragraph,
            clock: clock
        )
        _ = await coalescer.ingest("part one")
        clock.advance(byMilliseconds: 600)
        let merged = await coalescer.flushIfIdle()
        #expect(merged.count == 1)
        #expect(merged[0].contains("part one"))
    }

    @Test("Uses paragraph joiner when merging")
    func joinerParagraph() async {
        let clock = TestStreamingClock()
        let coalescer = BlockCoalescer(
            config: CoalescingConfig(enabled: true, idleMs: 100, minChars: 3),
            maxChars: 2000,
            breakPreference: .paragraph,
            clock: clock
        )
        _ = await coalescer.ingest("aaa")
        _ = await coalescer.ingest("bbb")
        clock.advance(byMilliseconds: 200)
        let merged = await coalescer.flushIfIdle()
        #expect(merged.first?.contains("\n\n") == true)
    }

    @Test("FlushFinal always emits remainder")
    func flushFinal() async {
        let coalescer = BlockCoalescer(
            config: CoalescingConfig(enabled: true, idleMs: 5000, minChars: 100),
            maxChars: 2000,
            breakPreference: .paragraph
        )
        _ = await coalescer.ingest("tiny")
        let final = await coalescer.flushFinal()
        #expect(final == ["tiny"])
    }

    @Test("Splits merged buffer exceeding maxChars")
    func maxCharsEarlyFlush() async {
        let coalescer = BlockCoalescer(
            config: CoalescingConfig(enabled: true, idleMs: 5000, minChars: 1),
            maxChars: 50,
            breakPreference: .paragraph
        )
        let block = String(repeating: "a", count: 60)
        let out = await coalescer.ingest(block)
        #expect(!out.isEmpty)
        for chunk in out {
            #expect(chunk.count <= 50)
        }
    }
}
