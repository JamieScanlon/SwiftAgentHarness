import Foundation
import SwiftAgentKit

/// Which participant controlled a conversation turn.
public enum TurnParty: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

/// One contiguous step in a conversation, made of one or more messages.
public struct ConversationTurn: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var party: TurnParty
    public var messageIDs: [UUID]
    /// Optional JSON string for expensive computed values (summary/compression/token stats).
    public var metadataJSON: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        party: TurnParty,
        messageIDs: [UUID],
        metadataJSON: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.party = party
        self.messageIDs = messageIDs
        self.metadataJSON = metadataJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Groups flat message history into conversation turns.
/// In `chat` and `plan` mode we currently keep UX/message handling flat and return no projection by default.
public func conversationTurns(
    interactionMode: InteractionMode,
    messages: [Message]
) -> [ConversationTurn] {
    guard interactionMode == .agent else { return [] }
    return conversationTurns(messages: messages)
}

/// Role-based grouping independent of interaction mode.
/// Rule: each user message starts a user turn; assistant+tool messages until next user are one assistant turn.
/// System messages are ignored for turn grouping.
public func conversationTurns(messages: [Message]) -> [ConversationTurn] {
    guard !messages.isEmpty else { return [] }

    var turns: [ConversationTurn] = []

    func appendTurn(party: TurnParty, ids: [UUID], first: Date?, last: Date?) {
        guard !ids.isEmpty else { return }
        turns.append(
            ConversationTurn(
                party: party,
                messageIDs: ids,
                createdAt: first,
                updatedAt: last
            )
        )
    }

    var currentParty: TurnParty?
    var currentIDs: [UUID] = []
    var currentFirst: Date?
    var currentLast: Date?
    var previousNonSystemMessage: Message?

    for message in messages {
        let party: TurnParty
        switch message.role {
        case .user:
            party = .user
        case .assistant, .tool:
            party = .assistant
        case .system:
            continue
        }

        let shouldSplitForAssistantNudge = {
            guard currentParty == .assistant, party == .assistant else { return false }
            guard let previous = previousNonSystemMessage else { return false }
            return previous.role == .assistant && previous.toolCalls.isEmpty && message.role == .assistant
        }()

        if currentParty == nil {
            currentParty = party
            currentFirst = message.timestamp
        } else if currentParty != party || party == .user || shouldSplitForAssistantNudge {
            appendTurn(party: currentParty ?? .assistant, ids: currentIDs, first: currentFirst, last: currentLast)
            currentParty = party
            currentIDs = []
            currentFirst = message.timestamp
            currentLast = nil
        }

        currentIDs.append(message.id)
        currentLast = message.timestamp
        previousNonSystemMessage = message
    }

    appendTurn(party: currentParty ?? .assistant, ids: currentIDs, first: currentFirst, last: currentLast)
    return turns
}
