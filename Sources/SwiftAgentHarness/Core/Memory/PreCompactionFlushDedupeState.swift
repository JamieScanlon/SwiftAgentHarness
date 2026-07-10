import CryptoKit
import Foundation
import SwiftAgentKit

enum PreCompactionFlushMiddleFingerprint: Sendable {
    static func of(messages: [Message]) -> String {
        let tuples: [[String: String]] = messages.map { message in
            [
                "content": message.content,
                "id": message.id.uuidString,
                "role": message.role.rawValue,
            ]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tuples) else { return "" }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PreCompactionFlushDedupeState: Sendable {
    private static let maxRecentFingerprints = 16

    private(set) var flushedMessageIDs: Set<UUID> = []
    private var recentFingerprints: [String] = []

    func filterNovelMiddle(_ middle: [Message]) -> [Message] {
        middle.filter { !flushedMessageIDs.contains($0.id) }
    }

    func shouldSkipFingerprint(_ fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return recentFingerprints.contains(fingerprint)
    }

    mutating func recordSuccessfulFlush(middle: [Message]) {
        for message in middle {
            flushedMessageIDs.insert(message.id)
        }
        let fingerprint = PreCompactionFlushMiddleFingerprint.of(messages: middle)
        guard !fingerprint.isEmpty else { return }
        recentFingerprints.append(fingerprint)
        if recentFingerprints.count > Self.maxRecentFingerprints {
            recentFingerprints.removeFirst(recentFingerprints.count - Self.maxRecentFingerprints)
        }
    }

    mutating func beginNewCycle() {
        flushedMessageIDs.removeAll()
        recentFingerprints.removeAll()
    }
}
