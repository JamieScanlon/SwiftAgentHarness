import SwiftAgentKit

/// Internal canonical adapter event shape used before projecting into `LLMResponse` stream chunks.
enum NormalizedEvent: Sendable, Equatable {
    case contentDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(id: String?, name: String?, argumentsFragment: String)
}

enum NormalizedEventMapper {
    static func streamChunk(for event: NormalizedEvent, availableTools: [ToolDefinition]) -> LLMResponse {
        switch event {
        case .contentDelta(let content):
            return LLMResponse
                .llmResponse(from: content, availableTools: availableTools)
                .removingToolCalls()
                .markingIncomplete()
        case .reasoningDelta(let reasoning):
            return LLMResponse.streamChunk("", streamingFragment: .reasoning(reasoning))
        case .toolCallDelta(let id, let name, let argumentsFragment):
            return LLMResponse.streamChunk(
                "",
                streamingFragment: .toolCall(
                    id: id,
                    name: name,
                    argumentsFragment: argumentsFragment
                )
            )
        }
    }
}
