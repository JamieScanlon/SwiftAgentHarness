//
//  README `subscribe(from_seq:)` seam: strategy-driven transcript replay + live tail.
//

import Foundation

enum TranscriptSubscribeTailStrategyKind: String, Sendable {
    case polling
    case multiHost
}

struct TranscriptSubscribeStreamContext: Sendable {
    var conversationID: UUID
    var inclusiveFrom: Int
    var retention: TranscriptTailRetentionPolicy?
    var pollInterval: Duration
}

private protocol TranscriptSubscribeTailStrategy: Sendable {
    var kind: TranscriptSubscribeTailStrategyKind { get }
    func entryEvents(
        context: TranscriptSubscribeStreamContext,
        clock: ContinuousClock,
        readEntries: @escaping @Sendable (SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry],
        latestSequence: @escaping @Sendable () throws -> Int
    ) -> AsyncThrowingStream<SessionTranscriptEntry, Error>
}

private struct TranscriptSubscribePollingTailStrategy: TranscriptSubscribeTailStrategy {
    let kind: TranscriptSubscribeTailStrategyKind = .polling

    func entryEvents(
        context: TranscriptSubscribeStreamContext,
        clock: ContinuousClock,
        readEntries: @escaping @Sendable (SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry],
        latestSequence: @escaping @Sendable () throws -> Int
    ) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        AsyncThrowingStream<SessionTranscriptEntry, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let initialHead = try latestSequence()
                    if let retention = context.retention {
                        try retention.requireReplayWindow(
                            conversationID: context.conversationID,
                            clientInclusiveFloor: context.inclusiveFrom,
                            latestSequence: initialHead
                        )
                    }
                    var nextExpected = context.inclusiveFrom
                    while !Task.isCancelled {
                        let batch = try readEntries(.init(fromSequence: nextExpected)).filter { $0.sequence >= nextExpected }
                        if !batch.isEmpty {
                            for entry in batch.sorted(by: { $0.sequence < $1.sequence }) where entry.sequence >= nextExpected {
                                continuation.yield(entry)
                                nextExpected = entry.sequence + 1
                            }
                            continue
                        }
                        let head = try latestSequence()
                        if head < nextExpected {
                            try await clock.sleep(for: context.pollInterval)
                        } else if head == 0, nextExpected == 0 {
                            try await clock.sleep(for: context.pollInterval)
                        } else {
                            // Head already at or past `nextExpected` but this read was empty
                            // (transient gap / ordering); never tight-loop — same poll cadence as tail wait.
                            try await clock.sleep(for: context.pollInterval)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private struct TranscriptSubscribeMultiHostTailStrategy: TranscriptSubscribeTailStrategy {
    let kind: TranscriptSubscribeTailStrategyKind = .multiHost
    let fallback: TranscriptSubscribePollingTailStrategy

    func entryEvents(
        context: TranscriptSubscribeStreamContext,
        clock: ContinuousClock,
        readEntries: @escaping @Sendable (SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry],
        latestSequence: @escaping @Sendable () throws -> Int
    ) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        // Multi-host subscribe is represented by this strategy boundary.
        // Until an external broker/file-watch transport is configured, it safely falls back to polling.
        fallback.entryEvents(
            context: context,
            clock: clock,
            readEntries: readEntries,
            latestSequence: latestSequence
        )
    }
}

enum TranscriptSubscriptionStream {
    /// Poll interval when waiting for ``latestSequence`` to reach the next expected row (override via `SAH_TRANSCRIPT_SUBSCRIBE_POLL_MS`).
    static func pollIntervalFromEnvironmentOrDefault() -> Duration {
        let raw = ProcessInfo.processInfo.environment["SAH_TRANSCRIPT_SUBSCRIBE_POLL_MS"]
        if let raw, let v = Int(raw), v > 0 {
            return .milliseconds(v)
        }
        return .milliseconds(50)
    }

    /// Yields ``SessionTranscriptEntry`` in strictly increasing ``sequence`` order, starting at ``inclusiveFrom`` (same floor as ``readTranscriptEntries(fromSequence:)``).
    ///
    /// Read-only: does not acquire the transcript write lock. ``retention`` uses the same lag rule as ``TranscriptTailPolling``.
    static func entryEvents(
        conversationID: UUID,
        inclusiveFrom: Int,
        retention: TranscriptTailRetentionPolicy?,
        pollInterval: Duration,
        preferredTailStrategy: TranscriptSubscribeTailStrategyKind = SessionPersistenceConfiguration.transcriptSubscribeTailStrategy,
        clock: ContinuousClock = .continuous,
        readEntries: @escaping @Sendable (SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry],
        latestSequence: @escaping @Sendable () throws -> Int
    ) -> AsyncThrowingStream<SessionTranscriptEntry, Error> {
        let context = TranscriptSubscribeStreamContext(
            conversationID: conversationID,
            inclusiveFrom: inclusiveFrom,
            retention: retention,
            pollInterval: pollInterval
        )
        let strategy = selectTailStrategy(preferredTailStrategy)
        return strategy.entryEvents(
            context: context,
            clock: clock,
            readEntries: readEntries,
            latestSequence: latestSequence
        )
    }

    private static func selectTailStrategy(_ preferred: TranscriptSubscribeTailStrategyKind) -> any TranscriptSubscribeTailStrategy {
        let polling = TranscriptSubscribePollingTailStrategy()
        switch preferred {
        case .polling:
            return polling
        case .multiHost:
            return TranscriptSubscribeMultiHostTailStrategy(fallback: polling)
        }
    }
}
