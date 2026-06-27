import EasyJSON
import Foundation
import SwiftAgentKit

enum MessageOutputPostProcessor {
    static func apply(
        envelope: HarnessMessageEnvelope,
        policy: MessageOutputPolicy
    ) -> HarnessMessageEnvelope {
        guard policy == .messageToolOnly else { return envelope }
        var out = envelope
        if let messageCall = out.message.toolCalls.first(where: { $0.name == MessageToolArgumentsParser.toolName }),
           let presentation = presentation(from: messageCall) {
            out.message.content = presentation.textFallback()
            return out
        }
        if out.message.toolCalls.isEmpty {
            out.message.content = ""
        }
        return out
    }

    private static func presentation(from toolCall: ToolCall) -> MessagePresentation? {
        guard case .object(let dict) = toolCall.arguments else { return nil }
        let title: String? = {
            guard case .string(let value) = dict["title"] else { return nil }
            return value
        }()
        let tone: MessageTone? = {
            guard case .string(let raw) = dict["tone"] else { return nil }
            return MessageTone(rawValue: raw)
        }()
        if case .string(let blocksRaw) = dict["blocks"],
           let blocksData = blocksRaw.data(using: .utf8),
           let blocks = try? JSONDecoder().decode([MessageBlock].self, from: blocksData) {
            return MessagePresentation(title: title, tone: tone, blocks: blocks)
        }
        if let data = try? JSONEncoder().encode(toolCall.arguments),
           let json = String(data: data, encoding: .utf8) {
            return MessageToolArgumentsParser.decodePresentation(from: json)
        }
        return nil
    }
}
