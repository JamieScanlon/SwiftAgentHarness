import Foundation

public enum ConversationOrigin: String, Codable, Sendable, CaseIterable {
    case user
    case system
}
