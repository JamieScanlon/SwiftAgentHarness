import Foundation

/// Injectable clock for deterministic coalescer tests.
public protocol StreamingClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until deadline: ContinuousClock.Instant) async
}

public struct ContinuousStreamingClock: StreamingClock {
    public init() {}

    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    public func sleep(until deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        try? await clock.sleep(until: deadline)
    }
}

/// Merges consecutive blocks on an idle gap before send.
public actor BlockCoalescer {
    private var pendingBlocks: [String] = []
    private var lastIngestInstant: ContinuousClock.Instant?
    private let config: CoalescingConfig
    private let maxChars: Int
    private let joiner: String
    private let clock: any StreamingClock

    public init(
        config: CoalescingConfig,
        maxChars: Int,
        breakPreference: BreakPreference,
        clock: any StreamingClock = ContinuousStreamingClock()
    ) {
        self.config = config
        self.maxChars = max(1, maxChars)
        self.joiner = breakPreference.joiner
        self.clock = clock
    }

    /// Queues a block; returns merged output ready to send after idle wait (may be empty).
    public func ingest(_ block: String) async -> [String] {
        guard config.enabled else {
            return block.isEmpty ? [] : [block]
        }
        guard !block.isEmpty else { return [] }

        pendingBlocks.append(block)
        lastIngestInstant = clock.now()

        if mergedLength() >= maxChars {
            return await flushNow()
        }
        return []
    }

    /// Waits for idle gap then flushes merged block if minChars met.
    public func flushIfIdle() async -> [String] {
        guard config.enabled else { return [] }
        guard !pendingBlocks.isEmpty else { return [] }
        guard let lastIngest = lastIngestInstant else { return [] }

        let deadline = lastIngest + .milliseconds(config.idleMs)
        let now = clock.now()
        if now < deadline {
            await clock.sleep(until: deadline)
        }

        if pendingBlocks.isEmpty { return [] }
        if mergedLength() < config.minChars {
            return []
        }
        return await flushNow()
    }

    /// Flushes whatever remains (end-of-turn always sends).
    public func flushFinal() async -> [String] {
        guard config.enabled else { return [] }
        if pendingBlocks.isEmpty { return [] }
        return await flushNow()
    }

    public func discardPending() {
        pendingBlocks = []
        lastIngestInstant = nil
    }

    private func mergedLength() -> Int {
        guard !pendingBlocks.isEmpty else { return 0 }
        return pendingBlocks.reduce(0) { $0 + $1.count } + joiner.count * (pendingBlocks.count - 1)
    }

    private func mergedText() -> String {
        pendingBlocks.joined(separator: joiner)
    }

    private func flushNow() async -> [String] {
        let text = mergedText()
        pendingBlocks = []
        lastIngestInstant = nil
        guard !text.isEmpty else { return [] }

        if text.count <= maxChars {
            return [text]
        }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
