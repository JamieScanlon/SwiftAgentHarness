import Foundation

public enum ConversationLineageKind: String, Codable, Sendable, CaseIterable {
    case root
    case branch
    case subAgent
}
