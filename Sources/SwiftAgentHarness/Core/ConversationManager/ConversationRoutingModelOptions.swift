import Foundation

public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum ThinkingConfig: Codable, Sendable, Equatable {
    case disabled
    case adaptive
    case level(ThinkingLevel, budgetTokens: Int?)

    private enum CodingKeys: String, CodingKey {
        case level
        case budgetTokens
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            switch raw {
            case "disabled":
                self = .disabled
            case "adaptive":
                self = .adaptive
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported thinkingConfig string value")
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let level = try container.decode(ThinkingLevel.self, forKey: .level)
        let budgetTokens = try container.decodeIfPresent(Int.self, forKey: .budgetTokens)
        self = .level(level, budgetTokens: budgetTokens)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .disabled:
            var container = encoder.singleValueContainer()
            try container.encode("disabled")
        case .adaptive:
            var container = encoder.singleValueContainer()
            try container.encode("adaptive")
        case .level(let level, let budgetTokens):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(level, forKey: .level)
            try container.encodeIfPresent(budgetTokens, forKey: .budgetTokens)
        }
    }
}

public struct ConversationRoutingModelOptions: Codable, Sendable, Equatable {
    public var thinkingConfig: ThinkingConfig?

    public init(thinkingConfig: ThinkingConfig? = nil) {
        self.thinkingConfig = thinkingConfig
    }
}
