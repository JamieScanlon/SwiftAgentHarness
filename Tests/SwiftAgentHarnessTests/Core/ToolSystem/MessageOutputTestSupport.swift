import Foundation
import SwiftAgentKit
@testable import SwiftAgentHarness

enum MessageOutputTestSupport {
    static func emptyTurnStopLLMResponse() -> LLMResponse {
        LLMResponse(content: "", toolCalls: [])
    }

    static func messageToolLLMResponse(text: String, toolCallID: String = UUID().uuidString) -> LLMResponse {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let blocksJSON = "[{\"type\":\"text\",\"text\":\"\(escaped)\"}]"
        return LLMResponse(
            content: "",
            toolCalls: [
                ToolCall(
                    name: MessageToolArgumentsParser.toolName,
                    arguments: .object(["blocks": .string(blocksJSON)]),
                    id: toolCallID
                ),
            ]
        )
    }
}
