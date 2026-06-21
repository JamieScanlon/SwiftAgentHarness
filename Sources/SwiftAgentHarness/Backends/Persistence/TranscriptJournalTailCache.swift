//
//  In-process journal stream tail cache for locked append paths.
//

import Foundation

struct JournalStreamTails: Sendable, Equatable {
    var global: Int
    var raw: Int
    var derived: Int
    var rawLastMessageID: UUID?
}

enum TranscriptJournalTailCache {
    private struct Entry: Sendable {
        var watermark: Int
        var tails: JournalStreamTails
    }

    private static let store = Store()

    static func invalidate(conversationID: UUID) {
        store.invalidate(conversationID: conversationID)
    }

    static func resolveTails(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) throws -> JournalStreamTails {
        let watermark = try harness.latestTranscriptSequence(conversationID: conversationID)
        if let tails = store.cachedTails(conversationID: conversationID, watermark: watermark) {
            return tails
        }

        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        let tails = JournalStreamTails(
            global: SessionTranscriptV2JournalTails.latestGlobalEventID(entries: entries),
            raw: SessionTranscriptV2JournalTails.latestRawStreamSequence(entries: entries),
            derived: SessionTranscriptV2JournalTails.latestDerivedStreamSequence(entries: entries),
            rawLastMessageID: SessionTranscriptV2JournalTails.latestRawTailMessageID(entries: entries)
        )
        store.store(conversationID: conversationID, watermark: watermark, tails: tails)
        return tails
    }

    static func recordAppend(
        conversationID: UUID,
        stream: ConversationJournalStream,
        transcriptSequence: Int,
        rawLastMessageID: UUID? = nil
    ) {
        store.recordAppend(
            conversationID: conversationID,
            stream: stream,
            transcriptSequence: transcriptSequence,
            rawLastMessageID: rawLastMessageID
        )
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [UUID: Entry] = [:]

        func invalidate(conversationID: UUID) {
            lock.lock()
            defer { lock.unlock() }
            cache.removeValue(forKey: conversationID)
        }

        func cachedTails(conversationID: UUID, watermark: Int) -> JournalStreamTails? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = cache[conversationID], entry.watermark == watermark else { return nil }
            return entry.tails
        }

        func store(conversationID: UUID, watermark: Int, tails: JournalStreamTails) {
            lock.lock()
            defer { lock.unlock() }
            cache[conversationID] = Entry(watermark: watermark, tails: tails)
        }

        func recordAppend(
            conversationID: UUID,
            stream: ConversationJournalStream,
            transcriptSequence: Int,
            rawLastMessageID: UUID? = nil
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard var entry = cache[conversationID] else { return }
            entry.tails.global += 1
            switch stream {
            case .raw:
                entry.tails.raw += 1
                if let rawLastMessageID {
                    entry.tails.rawLastMessageID = rawLastMessageID
                }
            case .derived:
                entry.tails.derived += 1
            }
            entry.watermark = transcriptSequence
            cache[conversationID] = entry
        }
    }
}
