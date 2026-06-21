//
//  Transcript read surface (append path still orchestrated in HarnessRuntimeSession until moved).
//
//  **Conformance:** only ``HarnessSessionPersistence`` (``SessionBackend``) should satisfy this protocol in product
//  code — a subgroup of the single README backend, not a standalone injection surface.
//

import Foundation

struct SessionTranscriptReadRequest: Sendable, Equatable {
    var fromSequence: Int?
    var toSequence: Int?
    var limit: Int?

    init(fromSequence: Int? = nil, toSequence: Int? = nil, limit: Int? = nil) {
        self.fromSequence = fromSequence
        self.toSequence = toSequence
        self.limit = limit
    }

    static var full: SessionTranscriptReadRequest {
        SessionTranscriptReadRequest()
    }
}

/// Per-conversation message journal as harness transcript `Entry` rows.
protocol TranscriptPersistence: Sendable {
    /// Snapshot of entries in ascending sequence, filtered by request bounds:
    /// - `fromSequence` is inclusive lower bound
    /// - `toSequence` is inclusive upper bound
    /// - `limit` caps rows returned after bounds are applied
    /// When `fromSequence != nil`, enforces the same replay-window policy as ``subscribeTranscript`` (``TranscriptTailRetentionPolicy`` / `SAH_TRANSCRIPT_TAIL_MAX_SEQUENCE_LAG`).
    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) throws -> [SessionTranscriptEntry]

    /// Last committed monotonic transcript sequence for the conversation (`0` when empty). Distinct from hub wire `seq`.
    func latestTranscriptSequence(conversationID: UUID) throws -> Int

    /// Stream transcript entries in strict ascending sequence order beginning at inclusive `fromSequence`.
    ///
    /// Acceptance guarantees shared across backend strategies:
    /// - Replay retention contract matches ``readTranscriptEntries(conversationID:request:)`` when bounded by `fromSequence`.
    /// - Cancellation immediately terminates producer work.
    /// - Sequence monotonicity is preserved regardless of single-host polling vs multi-host tail transport.
    func subscribeTranscript(conversationID: UUID, fromSequence: Int) -> AsyncThrowingStream<SessionTranscriptEntry, Error>
}
