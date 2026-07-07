import Foundation
import SwiftAgentKit

struct AssistantMessageAccumulator {
    private var text = ""
    private var toolCallAccumulator = ToolCallAccumulator()
    private var contentBlocks: [HarnessContentBlock] = []
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
            appendTextDelta(chunk.content)
        }
        if let fragment = chunk.streamingFragment {
            switch fragment {
            case .text(let delta):
                if !delta.isEmpty {
                    text += delta
                    appendTextDelta(delta)
                }
            case .reasoning(let reasoning):
                appendThinkingDelta(reasoning)
            case .toolCall(let id, let name, let args):
                toolCallAccumulator.ingestNameAndArgs(id: id, name: name, argumentsFragment: args)
            case .toolCallStarted(let id, let name, _):
                contentBlocks.append(.toolUse(id: id, name: name))
            case .toolCallCompleted(let id, let name, let arguments):
                toolCallAccumulator.ingestNameAndArgs(id: id, name: name, argumentsFragment: arguments)
            }
        }
        if !chunk.toolCalls.isEmpty {
            toolCallAccumulator.ingestFinalList(chunk.toolCalls)
        }
    }

    private mutating func appendTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if case .text(let existing)? = contentBlocks.last {
            contentBlocks[contentBlocks.count - 1] = .text(existing + delta)
        } else {
            contentBlocks.append(.text(delta))
        }
    }

    private mutating func appendThinkingDelta(_ delta: String, signature: String? = nil) {
        guard !delta.isEmpty || signature != nil else { return }
        if case .thinking(let existing, let existingSignature)? = contentBlocks.last,
           signature == nil || signature == existingSignature {
            contentBlocks[contentBlocks.count - 1] = .thinking(
                text: existing + delta,
                signature: existingSignature ?? signature
            )
        } else {
            contentBlocks.append(.thinking(text: delta, signature: signature))
        }
    }

    func finalize() -> HarnessMessageEnvelope {
        let toolCalls = toolCallAccumulator.finalize()
        let content = finalResponse?.content.isEmpty == false ? finalResponse!.content : text
        let images = finalResponse?.images ?? []
        let message = Message(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            images: images,
            toolCalls: toolCalls
        )
        var blocks = contentBlocks
        if blocks.isEmpty, !content.isEmpty {
            blocks = [.text(content)]
        }
        return HarnessMessageEnvelope(message: message, contentBlocks: blocks)
    }
}
