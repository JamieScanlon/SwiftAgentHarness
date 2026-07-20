import Foundation
import SwiftAgentKit

enum ContextCacheTTLPruning: Sendable {
    static func deterministicReferenceInstant(from messages: [Message]) -> Date {
        messages.map(\.timestamp).max() ?? .distantPast
    }

    static func applyIfNeeded(
        messages: [Message],
        policy: ContextPruningPolicy,
        lastLLMDate: Date?,
        referenceInstant: Date,
        toolCallResolutionContext: [Message]
    ) -> (messages: [Message], transformationKind: CacheProjectionTransformationKind) {
        guard policy.mode == .cacheTTL,
              let ttl = policy.ttlSeconds, ttl > 0,
              let lastLLMDate
        else {
            return (messages, .cacheNeutral)
        }
        guard referenceInstant.timeIntervalSince(lastLLMDate) >= ttl else {
            return (messages, .cacheNeutral)
        }

        let toolCallIdToCall = ContextCompactionToolResultPruning.toolCallIdToCallMap(
            resolutionContext: toolCallResolutionContext,
            messages: messages
        )
        let placeholder = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        let ageCutoff = referenceInstant.addingTimeInterval(-ttl)
        let keepRecent = max(0, policy.keepRecentToolResults)

        var toolIndices: [Int] = []
        for (index, message) in messages.enumerated() where message.role == .tool {
            guard message.content != placeholder,
                  let toolCallID = message.toolCallId, !toolCallID.isEmpty,
                  let toolCall = toolCallIdToCall[toolCallID]
            else { continue }
            if let targetTools = policy.targetTools, !targetTools.contains(toolCall.name) {
                continue
            }
            toolIndices.append(index)
        }
        let protectedIndices = Set(toolIndices.suffix(keepRecent))

        var indicesToClear: Set<Int> = []
        for index in toolIndices where !protectedIndices.contains(index) {
            if messages[index].timestamp <= ageCutoff {
                indicesToClear.insert(index)
            }
        }
        guard !indicesToClear.isEmpty else {
            return (messages, .cacheNeutral)
        }

        var output = Array(messages)
        for index in indicesToClear {
            let message = output[index]
            output[index] = Message(
                id: message.id,
                role: message.role,
                content: placeholder,
                timestamp: message.timestamp,
                images: message.images,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId,
                responseFormat: message.responseFormat
            )
        }
        return (output, .cacheEditing)
    }
}
