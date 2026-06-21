import Foundation
import SwiftAgentKit

struct AssistantMessageAccumulator {
    private var text = ""
    private var toolCallAccumulator = ToolCallAccumulator()
    private var finalResponse: LLMResponse?

    mutating func consume(_ event: ModelStreamEvent) {
        switch event {
        case .stream(let chunk):
            ingestChunk(chunk)
        case .complete(let response):
            finalResponse = response
            if !response.toolCalls.isEmpty {
                toolCallAccumulator.ingestFinalList(response.toolCalls)
            }
            if !response.content.isEmpty, text.isEmpty {
                text = response.content
            }
        }
    }

    private mutating func ingestChunk(_ chunk: LLMResponse) {
        if !chunk.content.isEmpty {
            text += chunk.content
        }
        if let fragment = chunk.streamingFragment {
            switch fragment {
            case .text:
                break
            case .reasoning:
                break
            case .toolCall(let id, let name, let args):
                toolCallAccumulator.ingestNameAndArgs(id: id, name: name, argumentsFragment: args)
            @unknown default:
                break
            }
        }
        if !chunk.toolCalls.isEmpty {
            toolCallAccumulator.ingestFinalList(chunk.toolCalls)
        }
    }

    func finalize() -> Message {
        let toolCalls = toolCallAccumulator.finalize()
        let content = finalResponse?.content.isEmpty == false ? finalResponse!.content : text
        let images = finalResponse?.images ?? []
        return Message(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            images: images,
            toolCalls: toolCalls
        )
    }
}
