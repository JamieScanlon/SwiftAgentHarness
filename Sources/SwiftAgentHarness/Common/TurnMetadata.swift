import Foundation

/// Typed metadata stored on a conversation turn and serialized into `metadataJSON`.
public struct TurnMetadata: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var computedAt: Date
    /// Stable signature derived from the turn's message ids for invalidation checks.
    public var messageSignature: String
    public var summary: String?
    public var compressedText: String?
    public var tokenEstimate: Int?
    /// When a turn is transformed/replaced, these are the original message IDs that were compacted into this turn.
    public var originalMessageIDs: [UUID]?

    public init(
        schemaVersion: Int = TurnMetadata.currentSchemaVersion,
        computedAt: Date = Date(),
        messageSignature: String,
        summary: String? = nil,
        compressedText: String? = nil,
        tokenEstimate: Int? = nil,
        originalMessageIDs: [UUID]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.computedAt = computedAt
        self.messageSignature = messageSignature
        self.summary = summary
        self.compressedText = compressedText
        self.tokenEstimate = tokenEstimate
        self.originalMessageIDs = originalMessageIDs
    }
}

public enum TurnMetadataCodec {
    public static func encode(_ metadata: TurnMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> TurnMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TurnMetadata.self, from: data)
    }

    public static func signature(for messageIDs: [UUID]) -> String {
        messageIDs.map(\.uuidString).joined(separator: "|")
    }
}

public extension ConversationTurn {
    var typedMetadata: TurnMetadata? {
        TurnMetadataCodec.decode(metadataJSON)
    }
}
