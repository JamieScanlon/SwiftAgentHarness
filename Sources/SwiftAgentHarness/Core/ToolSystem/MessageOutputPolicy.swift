import Foundation

/// Controls how assistant-visible output is surfaced for a turn.
public enum MessageOutputPolicy: String, Sendable, Codable, Equatable {
    /// Stream model prose directly (legacy REST/TUI behavior).
    case legacyStreamedText
    /// User-visible output must come from the core `message` tool only.
    case messageToolOnly
}

public enum MessageOutputPolicyResolver {
    /// Resolves output policy from surface provenance and harness opt-out list.
    ///
    /// Turns with no `originSurface` stay on legacy streaming. All other surfaces default to
    /// ``MessageOutputPolicy/messageToolOnly`` unless listed in ``AgentHarnessConfiguration/legacyStreamedTextSurfaces``.
    public static func policy(
        originSurface: String?,
        legacyStreamedTextSurfaces: Set<String> = AgentHarnessConfiguration.default.legacyStreamedTextSurfaces
    ) -> MessageOutputPolicy {
        guard let originSurface, !originSurface.isEmpty else {
            return .legacyStreamedText
        }
        if ChannelId(rawValue: originSurface) != nil {
            return .messageToolOnly
        }
        switch originSurface {
        case ChannelId.slack.rawValue, ChannelId.telegram.rawValue,
             ChannelId.discord.rawValue, ChannelId.email.rawValue:
            return .messageToolOnly
        default:
            if legacyStreamedTextSurfaces.contains(originSurface) {
                return .legacyStreamedText
            }
            return .messageToolOnly
        }
    }
}
