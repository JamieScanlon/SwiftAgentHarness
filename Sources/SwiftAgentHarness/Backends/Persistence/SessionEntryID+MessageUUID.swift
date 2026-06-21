//
//  UUID ↔ 8-char hex conversion for transcript row keys (persistence layer only).
//

import Foundation
import SwiftAgentKit

extension SessionEntryID {
    static func fromMessageUUID(_ uuid: UUID) -> SessionEntryID {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return SessionEntryID(rawValue: String(hex.prefix(8)))
    }

    static func fromMessageUUIDs(_ uuids: [UUID]) -> [SessionEntryID] {
        uuids.map(fromMessageUUID)
    }

    static func matchingMessageID(for entryId: SessionEntryID, in messages: [Message]) -> UUID? {
        messages.first { fromMessageUUID($0.id) == entryId }?.id
    }

    static func messageUUID(for entryId: SessionEntryID, in entries: [SessionTranscriptEntry]) -> UUID? {
        for entry in entries where entry.type == .message || entry.type == .system {
            guard let payload = try? MessageTranscriptPayloadCodec.decode(entry.payloadJSON) else { continue }
            if fromMessageUUID(payload.id) == entryId {
                return payload.id
            }
        }
        return nil
    }
}
