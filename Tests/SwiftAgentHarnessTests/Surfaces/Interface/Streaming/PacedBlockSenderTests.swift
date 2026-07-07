import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PacedBlockSender")
struct PacedBlockSenderTests {
    @Test("Delivers blocks in FIFO order")
    func fifoOrder() async {
        let sink = RecordingStreamingSurfaceSink()
        let sender = PacedBlockSender(pacer: HumanPacer(config: .init(mode: .off)), sink: sink)
        await sender.enqueue("first")
        await sender.enqueue("second")
        await sender.drain()

        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks == ["first", "second"])
    }

    @Test("Drain waits until all queued blocks are sent")
    func drainWaitsForCompletion() async {
        let sink = RecordingStreamingSurfaceSink()
        let sender = PacedBlockSender(
            pacer: HumanPacer(config: .init(mode: .custom(minMs: 30, maxMs: 30))),
            sink: sink
        )
        await sender.enqueue("one")
        await sender.enqueue("two")
        await sender.drain()

        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks.count == 2)
    }

    @Test("Reset discards queued blocks")
    func resetDiscardsQueue() async {
        let sink = RecordingStreamingSurfaceSink()
        let sender = PacedBlockSender(
            pacer: HumanPacer(config: .init(mode: .custom(minMs: 100, maxMs: 100))),
            sink: sink
        )
        await sender.enqueue("first")
        await sender.enqueue("second")
        await sender.reset()
        await sender.drain()

        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks.isEmpty)
    }
}
