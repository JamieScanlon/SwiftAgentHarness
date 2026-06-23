//
//  persistence-backed transcript tail follow (polling MVP).
//
//  Design locks:
//  - Hub total-order / dual `seq` values stay in-memory; persisted `transcript.sequence` is the store cursor for catch-up (`readTranscriptEntries`, snapshots).
//  - Tail follow uses short polling of `latestTranscriptSequence` (test-friendly; file-watch is a future option).
//

import Foundation

/// Window for rejecting tail subscribers whose last-known transcript sequence is too far behind the current head.
public struct TranscriptTailRetentionPolicy: Sendable, Equatable {
    /// When `(latestSequence - clientFloorSequence) > maxSequenceLag`, subscribe fails with ``SessionPersistenceError/retentionExceeded``.
    public var maxSequenceLag: Int

    public init(maxSequenceLag: Int) {
        self.maxSequenceLag = maxSequenceLag
    }

    static func fromEnvironmentOrDefault() -> TranscriptTailRetentionPolicy {
        let raw = HarnessEnvironmentOverride.string("SAH_TRANSCRIPT_TAIL_MAX_SEQUENCE_LAG")
        // `0` is valid (reject any client floor below the current head); only negative values fall back.
        if let raw, let v = Int(raw), v >= 0 {
            return TranscriptTailRetentionPolicy(maxSequenceLag: v)
        }
        return TranscriptTailRetentionPolicy(maxSequenceLag: 500_000)
    }

    /// Rejects snapshot or subscribe floors when the store head is too far ahead of the client's inclusive sequence (Gap 14 / README replay window).
    ///
    /// Used by ``readTranscriptEntries`` (when `fromSequence != nil`) and ``TranscriptSubscriptionStream``. Same inequality as tail subscribe: throws ``SessionPersistenceError/retentionExceeded`` when `latestSequence - clientInclusiveFloor > maxSequenceLag`. Does not throw when `clientInclusiveFloor > latestSequence`.
    /// - Note: ``TranscriptTailPolling/tailEvents`` uses a different `sinceSequence` contract; it does not call this helper.
    func requireReplayWindow(conversationID: UUID, clientInclusiveFloor: Int, latestSequence: Int) throws {
        if latestSequence - clientInclusiveFloor > maxSequenceLag {
            throw SessionPersistenceError.retentionExceeded(
                conversationID: conversationID,
                clientFloorSequence: clientInclusiveFloor,
                latestSequence: latestSequence,
                maxAllowedLag: maxSequenceLag
            )
        }
    }
}

struct TranscriptTailEvent: Sendable, Equatable {
    var latestSequence: Int
}

enum TranscriptTailPolling {
    /// Monotonic notifications when the supplied ``latestSequence`` closure reports a higher value.
    /// - Parameters:
    ///   - sinceSequence: Last transcript sequence the caller already applied (exclusive floor); emission happens when `latest > sinceSequence`. `nil` means “only report growth after the initial poll.”
    ///   - latestSequence: Called on each poll; must read from the same harness install (typically ``HarnessSessionPersistence/latestTranscriptSequence``).
    static func tailEvents(
        conversationID: UUID,
        pollInterval: Duration,
        sinceSequence: Int?,
        retention: TranscriptTailRetentionPolicy?,
        latestSequence: @escaping @Sendable () throws -> Int,
        clock: ContinuousClock = .continuous
    ) -> AsyncThrowingStream<TranscriptTailEvent, Error> {
        AsyncThrowingStream<TranscriptTailEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let initialLatest = try latestSequence()
                    if let floor = sinceSequence, let r = retention {
                        if initialLatest - floor > r.maxSequenceLag {
                            throw SessionPersistenceError.retentionExceeded(
                                conversationID: conversationID,
                                clientFloorSequence: floor,
                                latestSequence: initialLatest,
                                maxAllowedLag: r.maxSequenceLag
                            )
                        }
                    }
                    var lastEmitted = sinceSequence ?? initialLatest
                    while !Task.isCancelled {
                        let latest = try latestSequence()
                        if latest > lastEmitted {
                            lastEmitted = latest
                            continuation.yield(TranscriptTailEvent(latestSequence: latest))
                        }
                        try await clock.sleep(for: pollInterval)
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
