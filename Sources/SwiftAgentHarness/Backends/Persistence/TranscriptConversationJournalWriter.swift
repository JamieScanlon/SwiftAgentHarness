//
//  Durable raw + derived journal rows on harness transcript (`conversation_journal`, `derived_journal`).
//

import Foundation
import SwiftAgentKit

enum TranscriptConversationJournalWriter {
    static func loadEventsWithFrontier(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> ([CachedConversationEvent], Int) {
        guard let entries = try? harness.readTranscriptEntries(conversationID: conversationID, request: .full) else {
            return ([], 0)
        }
        return SessionTranscriptV2JournalMapping.cachedEvents(from: entries, conversationID: conversationID)
    }

    static func latestRawStreamSequence(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> Int {
        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        return SessionTranscriptV2JournalTails.latestRawStreamSequence(entries: entries)
    }

    static func latestDerivedStreamSequence(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> Int {
        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        return SessionTranscriptV2JournalTails.latestDerivedStreamSequence(entries: entries)
    }

    static func latestGlobalEventID(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> Int {
        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        return SessionTranscriptV2JournalTails.latestGlobalEventID(entries: entries)
    }

    static func latestRawTailMessageID(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> UUID? {
        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        return SessionTranscriptV2JournalTails.latestRawTailMessageID(entries: entries)
    }

    static func appendRawJournalEntry(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        kind: ConversationEventKind,
        innerPayloadJSON: String,
        createdAt: Date,
        expectedRawSequence: Int?
    ) throws {
        try appendJournalEnvelopeAtomically(
            harness: harness,
            conversationID: conversationID,
            stream: .raw,
            kind: kind,
            innerPayloadJSON: innerPayloadJSON,
            basedOnEventID: nil,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: createdAt,
            expectedStreamSequence: expectedRawSequence,
            entryType: .conversationJournal,
            defaultBasedOnGlobalPredecessor: true
        )
    }

    static func appendMessageAppendedEvents(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID? = nil
    ) throws {
        guard !messages.isEmpty else { return }
        let lock = try harness.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }

        let tails = try TranscriptJournalTailCache.resolveTails(harness: harness, conversationID: conversationID)
        if let expected = expectedLastMessageId, tails.rawLastMessageID != expected {
            throw ConversationServiceError.transcriptTailMismatch(
                conversationID: conversationID,
                expectedTailMessageID: expected,
                actualTailMessageID: tails.rawLastMessageID
            )
        }

        var nextGlobal = tails.global
        var nextRaw = tails.raw
        var parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: harness
        )
        for message in messages {
            nextGlobal += 1
            nextRaw += 1
            let inner = ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: message.id))
            let env = SessionTranscriptJournalEnvelope(
                eventID: nextGlobal,
                journalStreamRaw: ConversationJournalStream.raw.rawValue,
                streamSequence: nextRaw,
                kind: ConversationEventKind.messageAppended.rawValue,
                basedOnEventID: nextGlobal - 1,
                coversStartEventID: nil,
                coversEndEventID: nil,
                innerPayloadJSON: inner
            )
            let entry = try persistJournalEntry(
                harness: harness,
                conversationID: conversationID,
                envelope: env,
                entryType: .conversationJournal,
                timestamp: message.timestamp,
                parentEntryId: parentEntryId
            )
            TranscriptJournalTailCache.recordAppend(
                conversationID: conversationID,
                stream: .raw,
                transcriptSequence: entry.sequence,
                rawLastMessageID: message.id
            )
            parentEntryId = entry.entryId
        }
    }

    static func appendDerivedJournalEntry(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        kind: ConversationEventKind,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        try appendJournalEnvelopeAtomically(
            harness: harness,
            conversationID: conversationID,
            stream: .derived,
            kind: kind,
            innerPayloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedStreamSequence: expectedDerivedSequence,
            entryType: .derivedJournal,
            defaultBasedOnGlobalPredecessor: false
        )
    }

    private static func appendJournalEnvelopeAtomically(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        stream: ConversationJournalStream,
        kind: ConversationEventKind,
        innerPayloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedStreamSequence: Int?,
        entryType: SessionTranscriptEntryType,
        defaultBasedOnGlobalPredecessor: Bool
    ) throws {
        let lock = try harness.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }

        let tails = try TranscriptJournalTailCache.resolveTails(harness: harness, conversationID: conversationID)
        let tail = stream == .raw ? tails.raw : tails.derived
        let expectedSeq = expectedStreamSequence ?? tail
        if expectedSeq != tail {
            throw JournalStreamSequenceConflict(stream: stream, expected: expectedSeq, actual: tail)
        }

        let globalNext = tails.global + 1
        let streamNext = tail + 1
        let resolvedBasedOn = basedOnEventID ?? (defaultBasedOnGlobalPredecessor ? globalNext - 1 : nil)
        let env = SessionTranscriptJournalEnvelope(
            eventID: globalNext,
            journalStreamRaw: stream.rawValue,
            streamSequence: streamNext,
            kind: kind.rawValue,
            basedOnEventID: resolvedBasedOn,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            innerPayloadJSON: innerPayloadJSON
        )
        let entry = try persistJournalEntry(
            harness: harness,
            conversationID: conversationID,
            envelope: env,
            entryType: entryType,
            timestamp: createdAt,
            parentEntryId: try? ConversationTranscriptLineage.resolvedHeadEntryId(
                conversationID: conversationID,
                harness: harness
            )
        )
        TranscriptJournalTailCache.recordAppend(
            conversationID: conversationID,
            stream: stream,
            transcriptSequence: entry.sequence
        )
    }

    private static func persistJournalEntry(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        envelope: SessionTranscriptJournalEnvelope,
        entryType: SessionTranscriptEntryType,
        timestamp: Date,
        parentEntryId: SessionEntryID?
    ) throws -> SessionTranscriptEntry {
        let json = try SessionTranscriptJournalEnvelopeCodec.encode(envelope)
        let seq = try harness.nextTranscriptSequence(conversationID: conversationID)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: parentEntryId,
            type: entryType,
            timestamp: timestamp,
            payloadJSON: json
        )
        try harness.appendMirroredTranscriptEntry(conversationID: conversationID, entry: entry)
        return entry
    }

    static func eventIDForMessage(
        harness: any HarnessSessionPersistence,
        conversationID: UUID,
        messageID: UUID
    ) -> Int? {
        let (events, _) = loadEventsWithFrontier(harness: harness, conversationID: conversationID)
        for event in events where event.kind == ConversationEventKind.messageAppended.rawValue {
            if let payload = ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: event.payloadJSON),
               payload.messageID == messageID
            {
                return event.eventID
            }
        }
        return nil
    }

    static func fetchLatestTurnFinalizedEvent(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> CachedConversationEvent? {
        let (events, _) = loadEventsWithFrontier(harness: harness, conversationID: conversationID)
        return events
            .filter { $0.kind == ConversationEventKind.turnFinalized.rawValue }
            .max(by: { $0.eventID < $1.eventID })
    }

    static func latestCompactionAppliedUptoEventID(
        harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> Int? {
        let (events, _) = loadEventsWithFrontier(harness: harness, conversationID: conversationID)
        return events
            .filter { $0.kind == ConversationEventKind.compactionApplied.rawValue }
            .map(\.eventID)
            .max()
    }
}
