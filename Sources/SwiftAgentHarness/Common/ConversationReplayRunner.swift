//
//  Shared helpers for transcript sandbox replay (`ConversationReplayService`).
//

import Foundation
import SwiftAgentKit

enum ConversationReplayRunner {}

extension ConversationReplayRunner {
    static func messageBatches(from messages: [Message]) -> [[Message]] {
        messages.map { [$0] }
    }

    static func toolCall(for toolMessage: Message, replayedMessages: [Message]) -> ToolCall {
        if let toolCallID = toolMessage.toolCallId {
            for message in replayedMessages.reversed() where message.role == .assistant {
                if let match = message.toolCalls.first(where: { $0.id == toolCallID }) {
                    return match
                }
            }
            return ToolCall(name: "replay_tool", arguments: .object([:]), id: toolCallID)
        }
        for message in replayedMessages.reversed() where message.role == .assistant {
            if let toolCall = message.toolCalls.last {
                return toolCall
            }
        }
        return ToolCall(name: "replay_tool", arguments: .object([:]), id: nil)
    }
}
