import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Clears prior bash/process tool results in a conversation when exec approval is denied.
actor ExecDenialHygieneService: ExecApprovalDenialHygieneHandling {
    private let persistenceDomain: ConversationPersistenceDomain
    private let refreshProjection: @Sendable (UUID) async -> Void
    private let logger: Logger?

    init(
        persistenceDomain: ConversationPersistenceDomain,
        refreshProjection: @escaping @Sendable (UUID) async -> Void,
        logger: Logger? = nil
    ) {
        self.persistenceDomain = persistenceDomain
        self.refreshProjection = refreshProjection
        self.logger = logger
    }

    func poisonPriorMatchingToolResults(
        conversationID: UUID,
        deniedCommand: String,
        excludingToolCallId: String?
    ) async {
        let normalizedDenied = ExecApprovalCommandEquivalence.normalize(deniedCommand)
        guard !normalizedDenied.isEmpty else { return }

        do {
            let activeMessages = try await persistenceDomain.activeTranscriptMessages(conversationID: conversationID)
            let toolCallIdToCall = Self.buildToolCallIdToCall(from: activeMessages)
            let placeholder = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder

            var clearedMessageIDs: [UUID] = []
            var clearedToolCallIDs: [String] = []

            for message in activeMessages where message.role == .tool {
                guard message.content != placeholder else { continue }
                guard let toolCallId = message.toolCallId, !toolCallId.isEmpty else { continue }
                if let excludingToolCallId, toolCallId == excludingToolCallId { continue }
                guard let toolCall = toolCallIdToCall[toolCallId],
                      let priorCommand = Self.shellCommand(from: toolCall),
                      ExecApprovalCommandEquivalence.matches(priorCommand, deniedCommand)
                else { continue }

                let cleared = Message(
                    id: message.id,
                    role: message.role,
                    content: placeholder,
                    timestamp: message.timestamp,
                    images: message.images,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    responseFormat: message.responseFormat,
                    inputTrustRaw: message.inputTrustRaw
                )
                try await persistenceDomain.updateTranscriptMessagePayload(
                    conversationID: conversationID,
                    message: cleared
                )
                clearedMessageIDs.append(message.id)
                clearedToolCallIDs.append(toolCallId)
            }

            guard !clearedMessageIDs.isEmpty else { return }

            if var conversation = await persistenceDomain.modelConversation(id: conversationID) {
                for index in conversation.messages.indices {
                    guard clearedMessageIDs.contains(conversation.messages[index].id) else { continue }
                    conversation.messages[index].content = placeholder
                }
                await persistenceDomain.replaceConversationInRegistry(conversation)
            }

            try await persistenceDomain.recordExecDenialHygieneSideEffects(
                conversationID: conversationID,
                coveredMessageIDs: clearedMessageIDs,
                trimmedToolCallIDs: clearedToolCallIDs,
                logger: logger
            )
            await refreshProjection(conversationID)
        } catch {
            logger?.warning(
                "Exec denial hygiene failed for conversation \(conversationID): \(error)"
            )
        }
    }

    private static func buildToolCallIdToCall(from messages: [Message]) -> [String: ToolCall] {
        var map: [String: ToolCall] = [:]
        for message in messages where message.role == .assistant {
            for toolCall in message.toolCalls {
                if let id = toolCall.id { map[id] = toolCall }
            }
        }
        return map
    }

    private static func shellCommand(from toolCall: ToolCall) -> String? {
        let name = ToolNamePolicyNormalization.canonical(toolCall.name)
        guard name == "bash" || name == "process" else { return nil }
        guard case .object(let fields) = toolCall.arguments else { return nil }
        guard case .string(let command)? = fields["command"] else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : command
    }
}
