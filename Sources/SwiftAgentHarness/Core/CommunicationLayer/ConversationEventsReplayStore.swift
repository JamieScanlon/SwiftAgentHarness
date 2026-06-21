import Foundation

/// Bounded in-memory replay for `conversation/{id}/events`: one ring per topic ordered by total seq,
/// with optional `messageSeq` / `checkpointSeq` for dual-stream subscribe replay.
struct ConversationEventsReplayStore: Sendable {
    struct Entry: Sendable {
        let totalSeq: Int
        let messageSeq: Int?
        let checkpointSeq: Int?
        let json: String
    }

    private var entriesByTopic: [String: [Entry]] = [:]

    mutating func append(
        topic: String,
        totalSeq: Int,
        messageSeq: Int?,
        checkpointSeq: Int?,
        json: String,
        capacity: Int
    ) {
        guard capacity > 0 else {
            entriesByTopic[topic] = nil
            return
        }
        var entries = entriesByTopic[topic] ?? []
        if let last = entries.last, totalSeq <= last.totalSeq {
            if totalSeq == last.totalSeq {
                entries[entries.count - 1] = Entry(
                    totalSeq: totalSeq,
                    messageSeq: messageSeq,
                    checkpointSeq: checkpointSeq,
                    json: json
                )
                entriesByTopic[topic] = entries
            }
            return
        }
        entries.append(Entry(totalSeq: totalSeq, messageSeq: messageSeq, checkpointSeq: checkpointSeq, json: json))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        entriesByTopic[topic] = entries
    }

    /// Contiguous total-order replay `(sinceExclusive, latestTotalInclusive]`.
    func replayTotalOrder(topic: String, sinceExclusive: Int, latestTotalInclusive: Int) -> [String]? {
        guard latestTotalInclusive > sinceExclusive else { return [] }
        guard let entries = entriesByTopic[topic], !entries.isEmpty else { return nil }

        let slice = entries.filter { $0.totalSeq > sinceExclusive && $0.totalSeq <= latestTotalInclusive }
            .sorted { $0.totalSeq < $1.totalSeq }
        guard !slice.isEmpty else {
            return sinceExclusive == latestTotalInclusive ? [] : nil
        }
        var expected = sinceExclusive + 1
        var lines: [String] = []
        for e in slice {
            guard e.totalSeq == expected else { return nil }
            lines.append(e.json)
            expected += 1
        }
        guard expected - 1 == latestTotalInclusive else { return nil }
        return lines
    }

    /// Replay message-shaped events with contiguous `(sinceExclusive, latestMessageInclusive]` on `messageSeq`.
    func replayMessageStream(
        topic: String,
        sinceExclusive: Int?,
        latestMessageInclusive: Int,
        latestTotalInclusive: Int
    ) -> [String]? {
        guard let sinceExclusive else { return [] }
        if latestMessageInclusive <= sinceExclusive { return [] }

        guard let entries = entriesByTopic[topic], !entries.isEmpty else { return nil }

        let slice = entries.compactMap { e -> Entry? in
            guard let m = e.messageSeq, m > sinceExclusive, m <= latestMessageInclusive else { return nil }
            return e
        }.sorted { ($0.messageSeq!, $0.totalSeq) < ($1.messageSeq!, $1.totalSeq) }

        var expectedM = sinceExclusive + 1
        for e in slice {
            guard let m = e.messageSeq, m == expectedM else { return nil }
            expectedM += 1
        }
        guard expectedM - 1 == latestMessageInclusive else { return nil }

        let ordered = slice.sorted { $0.totalSeq < $1.totalSeq }
        guard ordered.last?.totalSeq ?? -1 <= latestTotalInclusive else { return nil }
        return ordered.map(\.json)
    }

    /// Replay checkpoint-shaped events with contiguous `(sinceExclusive, latestCheckpointInclusive]` on `checkpointSeq`.
    func replayCheckpointStream(
        topic: String,
        sinceExclusive: Int?,
        latestCheckpointInclusive: Int,
        latestTotalInclusive: Int
    ) -> [String]? {
        guard let sinceExclusive else { return [] }
        if latestCheckpointInclusive <= sinceExclusive { return [] }

        guard let entries = entriesByTopic[topic], !entries.isEmpty else { return nil }

        let slice = entries.compactMap { e -> Entry? in
            guard let c = e.checkpointSeq, c > sinceExclusive, c <= latestCheckpointInclusive else { return nil }
            return e
        }.sorted { ($0.checkpointSeq!, $0.totalSeq) < ($1.checkpointSeq!, $1.totalSeq) }

        var expectedC = sinceExclusive + 1
        for e in slice {
            guard let c = e.checkpointSeq, c == expectedC else { return nil }
            expectedC += 1
        }
        guard expectedC - 1 == latestCheckpointInclusive else { return nil }

        let ordered = slice.sorted { $0.totalSeq < $1.totalSeq }
        guard ordered.last?.totalSeq ?? -1 <= latestTotalInclusive else { return nil }
        return ordered.map(\.json)
    }

    /// Merge two replay segments (message + checkpoint) in total-order. Both slices must reference disjoint total seqs
    /// or Caller guarantees ordering; here we sort by total seq extracted from JSON is expensive — instead we concatenate
    /// with known lines from the same store: merge by walking sorted unique totalSeq keys.
    static func mergeByTotalSeq(messageLines: [String], checkpointLines: [String]) throws -> [String] {
        struct Tagged {
            let total: Int
            let json: String
        }
        func parseTotal(_ json: String) throws -> Int {
            guard let data = json.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seq = jsonInteger(obj["seq"])
            else {
                throw ConversationReplayMergeError.invalidJSON
            }
            return seq
        }
        var tagged: [Tagged] = []
        tagged.reserveCapacity(messageLines.count + checkpointLines.count)
        for j in messageLines {
            tagged.append(Tagged(total: try parseTotal(j), json: j))
        }
        for j in checkpointLines {
            tagged.append(Tagged(total: try parseTotal(j), json: j))
        }
        tagged.sort { $0.total < $1.total }
        var last: Int?
        for t in tagged {
            if let p = last, p == t.total { throw ConversationReplayMergeError.duplicateTotalSeq }
            last = t.total
        }
        return tagged.map(\.json)
    }

    private static func jsonInteger(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double, let i = Int(exactly: d) { return i }
        return nil
    }
}

enum ConversationReplayMergeError: Error {
    case invalidJSON
    case duplicateTotalSeq
}
