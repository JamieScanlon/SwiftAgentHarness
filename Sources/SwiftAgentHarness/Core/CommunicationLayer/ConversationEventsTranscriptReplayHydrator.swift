import Foundation
import SwiftAgentKit

/// Store-backed persisted replay metadata and JSON lines for `conversation/{id}/events` subscribe.
public struct ConversationTranscriptSubscribeReplay: Sendable {
    public var latestTotal: Int
    public var latestMessage: Int
    public var latestCheckpoint: Int
    public var persistedReplayLines: [String]
    /// When true, hydrator could not contiguously satisfy the client's cursor against the transcript store.
    public var forceLagging: Bool

    public init(
        latestTotal: Int,
        latestMessage: Int,
        latestCheckpoint: Int,
        persistedReplayLines: [String],
        forceLagging: Bool = false
    ) {
        self.latestTotal = latestTotal
        self.latestMessage = latestMessage
        self.latestCheckpoint = latestCheckpoint
        self.persistedReplayLines = persistedReplayLines
        self.forceLagging = forceLagging
    }

    public static let empty = ConversationTranscriptSubscribeReplay(
        latestTotal: 0,
        latestMessage: 0,
        latestCheckpoint: 0,
        persistedReplayLines: [],
        forceLagging: false
    )
}

enum ConversationEventsTranscriptReplayHydrator {
    /// Maps events replay cursors to the transcript subscribe/read inclusive floor semantics (`from_seq`).
    static func replayInclusiveFloor(_ replay: ConversationEventsReplayRequest) -> Int? {
        switch replay {
        case .totalOrderSince(let sinceExclusive):
            guard let sinceExclusive else { return nil }
            return max(0, sinceExclusive + 1)
        case .dual(let sinceMessage, let sinceCheckpoint):
            let floors = [sinceMessage, sinceCheckpoint]
                .compactMap { $0 }
                .map { max(0, $0 + 1) }
            return floors.min()
        }
    }

    static func streamHeads(entries: [SessionTranscriptEntry]) -> (latestMessage: Int, latestCheckpoint: Int) {
        var lm = 0
        var lc = 0
        for e in entries {
            if ConversationEventsReplayClassifier.isPersistedMessageStream(entry: e) {
                lm = max(lm, e.sequence)
            }
            if ConversationEventsReplayClassifier.isPersistedCheckpointStream(entry: e) {
                lc = max(lc, e.sequence)
            }
        }
        return (lm, lc)
    }

    /// Builds persisted replay JSON lines for the given subscribe request.
    static func persistedReplayLines(
        topic: String,
        conversationID: UUID,
        replay: ConversationEventsReplayRequest,
        entries: [SessionTranscriptEntry],
        latestTranscriptSequence: Int
    ) -> (lines: [String], lagging: Bool) {
        switch replay {
        case .totalOrderSince(let since):
            guard let since else { return ([], false) }
            return totalOrderReplay(
                topic: topic,
                sinceExclusive: since,
                latestTotal: latestTranscriptSequence,
                entries: entries
            )
        case .dual(let sinceM, let sinceC):
            if sinceM == nil, sinceC == nil { return ([], false) }
            return dualReplay(
                topic: topic,
                sinceMessage: sinceM,
                sinceCheckpoint: sinceC,
                entries: entries,
                latestTranscriptSequence: latestTranscriptSequence
            )
        }
    }

    private static func totalOrderReplay(
        topic: String,
        sinceExclusive: Int,
        latestTotal: Int,
        entries: [SessionTranscriptEntry]
    ) -> ([String], Bool) {
        guard latestTotal > 0 else { return ([], false) }
        if sinceExclusive == latestTotal { return ([], false) }
        if sinceExclusive > latestTotal { return ([], true) }
        let bySeq = Dictionary(uniqueKeysWithValues: entries.map { ($0.sequence, $0) })
        var lines: [String] = []
        for seq in (sinceExclusive + 1) ... latestTotal {
            guard let entry = bySeq[seq] else { return ([], true) }
            guard let json = encodePersistedLine(
                topic: topic,
                entry: entry,
                latestTranscriptSequence: latestTotal
            ) else {
                return ([], true)
            }
            lines.append(json)
        }
        return (lines, false)
    }

    private static func dualReplay(
        topic: String,
        sinceMessage: Int?,
        sinceCheckpoint: Int?,
        entries: [SessionTranscriptEntry],
        latestTranscriptSequence: Int
    ) -> ([String], Bool) {
        let heads = streamHeads(entries: entries)
        if let sm = sinceMessage, sm > heads.latestMessage { return ([], true) }
        if let sc = sinceCheckpoint, sc > heads.latestCheckpoint { return ([], true) }
        guard latestTranscriptSequence > 0 else { return ([], false) }

        var pieces: [(seq: Int, json: String)] = []

        if let sm = sinceMessage {
            let slice = entries.filter {
                ConversationEventsReplayClassifier.isPersistedMessageStream(entry: $0)
                    && $0.sequence > sm
                    && $0.sequence <= latestTranscriptSequence
            }
            for entry in slice {
                guard let json = encodePersistedLine(
                    topic: topic,
                    entry: entry,
                    latestTranscriptSequence: latestTranscriptSequence
                ) else {
                    return ([], true)
                }
                pieces.append((entry.sequence, json))
            }
        }

        if let sc = sinceCheckpoint {
            let slice = entries.filter {
                ConversationEventsReplayClassifier.isPersistedCheckpointStream(entry: $0)
                    && $0.sequence > sc
                    && $0.sequence <= latestTranscriptSequence
            }
            for entry in slice {
                guard let json = encodePersistedLine(
                    topic: topic,
                    entry: entry,
                    latestTranscriptSequence: latestTranscriptSequence
                ) else {
                    return ([], true)
                }
                pieces.append((entry.sequence, json))
            }
        }

        pieces.sort { $0.seq < $1.seq }
        var last: Int?
        for p in pieces {
            if let lv = last, lv == p.seq { return ([], true) }
            last = p.seq
        }
        return (pieces.map(\.json), false)
    }

    private static func encodePersistedLine(
        topic: String,
        entry: SessionTranscriptEntry,
        latestTranscriptSequence: Int
    ) -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if ConversationEventsReplayClassifier.isPersistedCheckpointStream(entry: entry) {
            guard let data = entry.payloadJSON.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ConversationCheckpointTopicEventWire.self, from: data)
            else { return nil }
            let payload = ConversationTopicWireEncoding.checkpointTopicPayload(wire: wire)
            let envelope = CommResourceTopicMessage(
                event: topic,
                seq: entry.sequence,
                value: payload,
                messageSeq: nil,
                checkpointSeq: entry.sequence,
                trustTag: .unknownRestricted
            )
            guard let out = try? enc.encode(envelope) else { return nil }
            return String(data: out, encoding: .utf8)
        }

        if ConversationEventsReplayClassifier.isPersistedMessageStream(entry: entry) {
            guard let message = try? SessionTranscriptMapping.messageForReplay(from: entry) else { return nil }
            let inner = ConversationTopicWireEncoding.messagesRefreshJSONUTF8(
                from: [message],
                latestTranscriptSequence: latestTranscriptSequence
            )
            let payload = ConversationTopicEventPayload.messagesRefreshJSONUTF8(inner)
            let envelope = CommResourceTopicMessage(
                event: topic,
                seq: entry.sequence,
                value: payload,
                messageSeq: entry.sequence,
                checkpointSeq: nil,
                trustTag: CommEnvelopeTrustTag.fromMessageInputTrustRaw(message.inputTrustRaw)
            )
            guard let out = try? enc.encode(envelope) else { return nil }
            return String(data: out, encoding: .utf8)
        }
        return nil
    }
}
