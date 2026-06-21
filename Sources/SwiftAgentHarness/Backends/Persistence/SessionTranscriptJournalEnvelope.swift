//
//  durable v2 transcript envelope for raw + derived conversation journal rows.
//

import Foundation

/// Wrapper JSON stored in `SessionTranscriptEntry.payloadJSON` for `.conversationJournal` / `.derivedJournal`.
struct SessionTranscriptJournalEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var eventID: Int
    /// ``ConversationJournalStream.rawValue``
    var journalStreamRaw: String
    var streamSequence: Int
    /// ``ConversationEventKind.rawValue``
    var kind: String
    var basedOnEventID: Int?
    var coversStartEventID: Int?
    var coversEndEventID: Int?
    /// Same JSON as SwiftData ``CachedConversationEvent/payloadJSON`` for this `kind`.
    var innerPayloadJSON: String

    func asCachedConversationEvent(conversationID: UUID, createdAt: Date) -> CachedConversationEvent {
        CachedConversationEvent(
            conversationID: conversationID,
            eventID: eventID,
            kind: kind,
            payloadJSON: innerPayloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            journalStreamRaw: journalStreamRaw,
            streamSequence: streamSequence
        )
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        eventID: Int,
        journalStreamRaw: String,
        streamSequence: Int,
        kind: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        innerPayloadJSON: String
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.journalStreamRaw = journalStreamRaw
        self.streamSequence = streamSequence
        self.kind = kind
        self.basedOnEventID = basedOnEventID
        self.coversStartEventID = coversStartEventID
        self.coversEndEventID = coversEndEventID
        self.innerPayloadJSON = innerPayloadJSON
    }

    init(from event: CachedConversationEvent) {
        self.init(
            eventID: event.eventID,
            journalStreamRaw: event.journalStreamRaw,
            streamSequence: event.streamSequence,
            kind: event.kind,
            basedOnEventID: event.basedOnEventID,
            coversStartEventID: event.coversStartEventID,
            coversEndEventID: event.coversEndEventID,
            innerPayloadJSON: event.payloadJSON
        )
    }
}

enum SessionTranscriptJournalEnvelopeCodec {
    static let allowedTopLevelKeys: Set<String> = [
        "schemaVersion",
        "eventID",
        "journalStreamRaw",
        "streamSequence",
        "kind",
        "basedOnEventID",
        "coversStartEventID",
        "coversEndEventID",
        "innerPayloadJSON",
    ]

    static func assertAllowlistedKeys(_ payloadJSON: String) throws {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "journal envelope is not a JSON object")
        }
        let keys = Set(obj.keys)
        guard keys.isSubset(of: allowedTopLevelKeys) else {
            let extra = keys.subtracting(allowedTopLevelKeys)
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "unknown journal envelope keys: \(extra.sorted())")
        }
    }

    static func decode(_ payloadJSON: String) throws -> SessionTranscriptJournalEnvelope {
        try assertAllowlistedKeys(payloadJSON)
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "journal envelope not utf-8")
        }
        do {
            let e = try JSONDecoder().decode(SessionTranscriptJournalEnvelope.self, from: data)
            guard e.schemaVersion == SessionTranscriptJournalEnvelope.currentSchemaVersion else {
                throw SessionPersistenceError.transcriptPayloadInvalid(reason: "unsupported journal schemaVersion")
            }
            return e
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "journal envelope decode failed")
        }
    }

    static func encode(_ envelope: SessionTranscriptJournalEnvelope) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(envelope)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum SessionTranscriptV2JournalTails {
    static func latestGlobalEventID(entries: [SessionTranscriptEntry]) -> Int {
        var m = 0
        for e in entries {
            if let env = try? SessionTranscriptJournalEnvelopeCodec.decode(e.payloadJSON) {
                m = max(m, env.eventID)
            }
        }
        return m
    }

    static func latestRawStreamSequence(entries: [SessionTranscriptEntry]) -> Int {
        var m = 0
        for e in entries where e.type == .conversationJournal {
            guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(e.payloadJSON),
                  env.journalStreamRaw == ConversationJournalStream.raw.rawValue
            else {
                continue
            }
            m = max(m, env.streamSequence)
        }
        return m
    }

    static func latestDerivedStreamSequence(entries: [SessionTranscriptEntry]) -> Int {
        var m = 0
        for e in entries where e.type == .derivedJournal {
            guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(e.payloadJSON),
                  env.journalStreamRaw == ConversationJournalStream.derived.rawValue
            else {
                continue
            }
            m = max(m, env.streamSequence)
        }
        return m
    }

    static func latestRawTailMessageID(entries: [SessionTranscriptEntry]) -> UUID? {
        let sorted = entries
            .filter { $0.type == .conversationJournal }
            .sorted { $0.sequence < $1.sequence }
        var last: UUID?
        for entry in sorted {
            guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON),
                  env.journalStreamRaw == ConversationJournalStream.raw.rawValue,
                  env.kind == ConversationEventKind.messageAppended.rawValue,
                  let payload = ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: env.innerPayloadJSON)
            else {
                continue
            }
            last = payload.messageID
        }
        return last
    }
}

enum SessionTranscriptV2JournalMapping {
    /// Journal-shaped ``CachedConversationEvent`` rows derived from v2 transcript (in-memory only; not SwiftData-persisted).
    static func cachedEvents(from entries: [SessionTranscriptEntry], conversationID: UUID) -> ([CachedConversationEvent], Int) {
        var out: [CachedConversationEvent] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            switch e.type {
            case .conversationJournal, .derivedJournal:
                guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(e.payloadJSON) else { continue }
                out.append(env.asCachedConversationEvent(conversationID: conversationID, createdAt: e.timestamp))
            default:
                continue
            }
        }
        out.sort { $0.eventID < $1.eventID }
        let frontier = out.last?.eventID ?? 0
        return (out, frontier)
    }
}
