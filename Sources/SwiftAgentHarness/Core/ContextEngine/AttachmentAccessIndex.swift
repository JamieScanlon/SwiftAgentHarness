import Foundation
import SwiftAgentKit

struct AttachmentAccessRecord: Sendable, Equatable {
    var lastAccessTurnIndex: Int
    var accessCount: Int
}

struct AttachmentAccessIndex: Sendable, Equatable {
    var currentTurnIndex: Int
    var recordsByAttachmentID: [UUID: AttachmentAccessRecord]

    func turnsSinceAccess(for attachmentID: UUID) -> Int {
        guard let record = recordsByAttachmentID[attachmentID] else {
            return 0
        }
        return max(0, currentTurnIndex - record.lastAccessTurnIndex)
    }

    func accessCount(for attachmentID: UUID) -> Int {
        recordsByAttachmentID[attachmentID]?.accessCount ?? 0
    }

    func lastAccessTurnIndex(for attachmentID: UUID) -> Int? {
        recordsByAttachmentID[attachmentID]?.lastAccessTurnIndex
    }
}

enum AttachmentAccessIndexBuilder {
    private static let readAttachmentToolName = ConversationAttachmentToolProvider.readAttachmentToolName

    static func build(
        messages: [Message],
        catalog: [ConversationAttachmentDescriptor],
        includeMentionScan: Bool = true
    ) -> AttachmentAccessIndex {
        let currentTurnIndex = messages.count
        var records: [UUID: AttachmentAccessRecord] = [:]
        let catalogIDs = Set(catalog.map(\.id))
        let catalogIDStrings = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id.uuidString.lowercased(), $0.id) })

        for (index, message) in messages.enumerated() {
            if message.role == .assistant {
                for toolCall in message.toolCalls where toolCall.name == readAttachmentToolName {
                    guard let raw = ToolPolicyArgumentExtractor.stringValue(toolCall.arguments, keys: ["attachment_id"]),
                          let attachmentID = UUID(uuidString: raw),
                          catalogIDs.contains(attachmentID) else {
                        continue
                    }
                    recordAccess(to: attachmentID, at: index, in: &records)
                }
            }
            if includeMentionScan, message.role == .user || message.role == .assistant {
                let lowered = message.content.lowercased()
                for (idString, attachmentID) in catalogIDStrings where lowered.contains(idString) {
                    recordAccess(to: attachmentID, at: index, in: &records)
                }
            }
        }

        for descriptor in catalog where records[descriptor.id] == nil {
            records[descriptor.id] = AttachmentAccessRecord(
                lastAccessTurnIndex: currentTurnIndex,
                accessCount: 0
            )
        }

        return AttachmentAccessIndex(
            currentTurnIndex: currentTurnIndex,
            recordsByAttachmentID: records
        )
    }

    private static func recordAccess(
        to attachmentID: UUID,
        at turnIndex: Int,
        in records: inout [UUID: AttachmentAccessRecord]
    ) {
        if var existing = records[attachmentID] {
            existing.lastAccessTurnIndex = turnIndex
            existing.accessCount += 1
            records[attachmentID] = existing
        } else {
            records[attachmentID] = AttachmentAccessRecord(
                lastAccessTurnIndex: turnIndex,
                accessCount: 1
            )
        }
    }
}
