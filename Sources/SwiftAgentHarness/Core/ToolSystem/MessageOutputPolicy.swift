import Foundation

/// Controls prompt guidance for assistant output on a turn. Prose always streams as `text_delta`.
public enum MessageOutputPolicy: String, Sendable, Codable, Equatable {
    /// Default for turns with no surface provenance; no structured-output reminder.
    case streamedProse
    /// Encourages structured `message` tool use on rich surfaces; prose still streams normally.
    case structuredPreferred
}

public enum MessageOutputPolicyResolver {
    /// Resolves output policy from surface provenance.
    ///
    /// Turns with no `originSurface` stay on ``MessageOutputPolicy/streamedProse``.
    /// All other surfaces receive ``MessageOutputPolicy/structuredPreferred`` guidance.
    /// ``AgentHarnessConfiguration/legacyStreamedTextSurfaces`` is deprecated and ignored.
    public static func policy(
        originSurface: String?,
        legacyStreamedTextSurfaces: Set<String> = AgentHarnessConfiguration.default.legacyStreamedTextSurfaces
    ) -> MessageOutputPolicy {
        _ = legacyStreamedTextSurfaces
        guard let originSurface, !originSurface.isEmpty else {
            return .streamedProse
        }
        return .structuredPreferred
    }
}
