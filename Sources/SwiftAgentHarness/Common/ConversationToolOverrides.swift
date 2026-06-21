import Foundation

/// Per-conversation model behavior overrides persisted as JSON (`CachedConversation.toolOverridesJSON`).
public struct ConversationToolOverrides: Codable, Sendable, Equatable {
    /// Optional per-conversation model options payload.
    public var modelOptions: ConversationRoutingModelOptions?

    public init(
        modelOptions: ConversationRoutingModelOptions? = nil
    ) {
        self.modelOptions = modelOptions
    }

    public static let empty = ConversationToolOverrides()

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw ConversationToolOverridesError.encodingFailed
        }
        return s
    }

    public static func parse(jsonString: String?) throws -> ConversationToolOverrides {
        guard let jsonString, !jsonString.isEmpty, let data = jsonString.data(using: .utf8) else {
            return .empty
        }
        return try JSONDecoder().decode(ConversationToolOverrides.self, from: data)
    }
}

public enum ConversationToolOverridesError: Error {
    case encodingFailed
}
