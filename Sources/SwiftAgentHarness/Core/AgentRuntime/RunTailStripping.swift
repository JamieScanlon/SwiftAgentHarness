import Foundation
import SwiftAgentKit

enum RunTailStripping {
    static func preserveThroughMessageID(messages: [Message], anchorUserMessageID: UUID) -> UUID? {
        guard let anchorIndex = messages.firstIndex(where: { $0.id == anchorUserMessageID && $0.role == .user }) else {
            return nil
        }
        let suffixStart = anchorIndex + 1
        guard suffixStart < messages.count else {
            return anchorUserMessageID
        }

        var lastPreservedIndex = anchorIndex
        var index = suffixStart
        while index < messages.count {
            let message = messages[index]
            switch message.role {
            case .assistant:
                if message.toolCalls.isEmpty {
                    if index == messages.count - 1 {
                        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty || !message.images.isEmpty {
                            lastPreservedIndex = index
                        }
                        return messages[lastPreservedIndex].id
                    }
                    lastPreservedIndex = index
                    index += 1
                } else {
                    let requiredCallIDs = Set(message.toolCalls.map(\.id))
                    var matchedCallIDs = Set<String>()
                    var probe = index + 1
                    while probe < messages.count, messages[probe].role == .tool {
                        if let callID = messages[probe].toolCallId {
                            matchedCallIDs.insert(callID)
                        }
                        probe += 1
                    }
                    if requiredCallIDs.isSubset(of: matchedCallIDs) {
                        lastPreservedIndex = probe > index + 1 ? probe - 1 : index
                        index = probe
                    } else {
                        return messages[lastPreservedIndex].id
                    }
                }
            case .tool:
                index += 1
            default:
                index += 1
            }
        }
        return messages[lastPreservedIndex].id
    }
}
