import Foundation
import SwiftAgentKit

/// Unions in-memory registry transcripts when concurrent writers race on ``ConversationManager/replaceConversationInRegistry(_:)``.
enum RegistryTranscriptMerge {

    /// Unions two in-memory transcripts by message ID.
    ///
    /// - Preserves existing order for shared IDs.
    /// - Incoming wins on same-ID conflicts (fresher snapshot fields, e.g. thumbs).
    /// - Appends incoming-only messages after the existing spine, ordered by timestamp.
    static func union(existing: [Message], incoming: [Message]) -> [Message] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        var incomingByID: [UUID: Message] = [:]
        incomingByID.reserveCapacity(incoming.count)
        for message in incoming {
            incomingByID[message.id] = message
        }

        var existingIDs = Set<UUID>()
        existingIDs.reserveCapacity(existing.count)
        var merged: [Message] = []
        merged.reserveCapacity(existing.count + incoming.count)

        for message in existing {
            existingIDs.insert(message.id)
            merged.append(incomingByID[message.id] ?? message)
        }

        var extras: [(index: Int, message: Message)] = []
        extras.reserveCapacity(incoming.count)
        for (index, message) in incoming.enumerated() where !existingIDs.contains(message.id) {
            extras.append((index, message))
        }
        guard !extras.isEmpty else { return merged }

        extras.sort { lhs, rhs in
            if lhs.message.timestamp != rhs.message.timestamp {
                return lhs.message.timestamp < rhs.message.timestamp
            }
            return lhs.index < rhs.index
        }
        merged.append(contentsOf: extras.map(\.message))
        return merged
    }
}
