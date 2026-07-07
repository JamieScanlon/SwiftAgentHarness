import Foundation

/// Serializes block sends with inter-bubble pacing off the streaming engine actor.
actor PacedBlockSender {
    private let pacer: HumanPacer
    private let sink: any StreamingSurfaceSink
    private var queue: [String] = []
    private var processing = false
    private var sentCount = 0
    private var runGeneration = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(pacer: HumanPacer, sink: any StreamingSurfaceSink) {
        self.pacer = pacer
        self.sink = sink
    }

    func enqueue(_ block: String) {
        guard !block.isEmpty else { return }
        queue.append(block)
        if !processing {
            processing = true
            let generation = runGeneration
            Task { await runLoop(generation: generation) }
        }
    }

    func drain() async {
        if queue.isEmpty, !processing {
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func reset() {
        runGeneration += 1
        queue.removeAll()
        sentCount = 0
        processing = false
        resumeDrainWaiters()
    }

    private func runLoop(generation: Int) async {
        while !queue.isEmpty {
            guard generation == runGeneration else { return }

            let block = queue.removeFirst()
            let isFirst = sentCount == 0
            await pacer.sleepIfNeeded(isFirstBlock: isFirst, isFinalReply: false, isToolSummary: false)
            guard generation == runGeneration else { return }

            await sink.sendBlock(block)
            sentCount += 1
        }
        guard generation == runGeneration else { return }
        processing = false
        resumeDrainWaiters()
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
