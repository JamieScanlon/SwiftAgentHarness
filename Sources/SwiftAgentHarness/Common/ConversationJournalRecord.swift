//
//  In-memory conversation journal row (durable store is harness transcript envelopes).
//
import Foundation

/// Logical journal event (raw or derived stream); not persisted via SwiftData on schema V22+.
public struct ConversationJournalEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var eventID: Int
    public var kind: String
    public var payloadJSON: String
    public var basedOnEventID: Int?
    public var coversStartEventID: Int?
    public var coversEndEventID: Int?
    public var createdAt: Date
    public var journalStreamRaw: String
    public var streamSequence: Int

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        eventID: Int,
        kind: String,
        payloadJSON: String = "{}",
        basedOnEventID: Int? = nil,
        coversStartEventID: Int? = nil,
        coversEndEventID: Int? = nil,
        createdAt: Date = Date(),
        journalStreamRaw: String,
        streamSequence: Int
    ) {
        self.id = id
        self.conversationID = conversationID
        self.eventID = eventID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.basedOnEventID = basedOnEventID
        self.coversStartEventID = coversStartEventID
        self.coversEndEventID = coversEndEventID
        self.createdAt = createdAt
        self.journalStreamRaw = journalStreamRaw
        self.streamSequence = streamSequence
    }

    public init(
        conversationID: UUID,
        eventID: Int,
        kind: String,
        payloadJSON: String,
        basedOnEventID: Int? = nil,
        coversStartEventID: Int? = nil,
        coversEndEventID: Int? = nil,
        createdAt: Date = Date(),
        streamSequence: Int? = nil
    ) {
        let stream = ConversationJournalStream(persistedEventKind: kind)
        let seq = streamSequence ?? eventID
        self.init(
            conversationID: conversationID,
            eventID: eventID,
            kind: kind,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            journalStreamRaw: stream.rawValue,
            streamSequence: seq
        )
    }

    public init(
        conversationID: UUID,
        eventID: Int,
        kind: String,
        payloadJSON: String,
        createdAt: Date
    ) {
        self.init(
            conversationID: conversationID,
            eventID: eventID,
            kind: kind,
            payloadJSON: payloadJSON,
            createdAt: createdAt,
            streamSequence: nil
        )
    }
}

/// Compaction background snapshot metadata carried in derived events (not a separate SwiftData table on V22+).
public struct ConversationJournalSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var uptoEventID: Int
    public var stateJSON: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        uptoEventID: Int,
        stateJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.uptoEventID = uptoEventID
        self.stateJSON = stateJSON
        self.createdAt = createdAt
    }
}

public typealias CachedConversationEvent = ConversationJournalEvent
public typealias CachedConversationSnapshot = ConversationJournalSnapshot
