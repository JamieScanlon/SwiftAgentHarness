import Foundation
import Logging

struct DefaultChannelSecurityAdapter: ChannelSecurityAdapting {
    let config: ChannelListenerConfig

    func isAllowed(event: ChannelMessageEvent, config: ChannelListenerConfig) -> Bool {
        ChannelAllowlistPolicy.isAllowed(event: event, config: config)
    }

    func makeMentionGate(config: ChannelMentionConfig) -> ChannelMentionGate {
        ChannelMentionGate(config: config)
    }

    func classifyTrust(
        event: ChannelMessageEvent,
        config: ChannelListenerConfig,
        effectiveWasMentioned: Bool
    ) -> CommEnvelopeOriginTrust {
        ChannelTrustClassifier.classify(
            event: event,
            config: config,
            effectiveWasMentioned: effectiveWasMentioned
        )
    }

    func redactLogIdentifier(_ value: String) -> String {
        ChannelIdentifierRedaction.redact(value)
    }
}

enum ChannelIdentifierRedaction {
    static func redact(_ value: String) -> String {
        if value.contains("@") {
            let parts = value.split(separator: "@", maxSplits: 1)
            guard let user = parts.first else { return "***" }
            return "\(user.prefix(2))***@\(parts.count > 1 ? parts[1] : "redacted")"
        }
        if value.allSatisfy(\.isNumber), value.count >= 7 {
            return String(repeating: "*", count: max(4, value.count - 4)) + value.suffix(4)
        }
        if value.count <= 4 { return "***" }
        return String(value.prefix(2)) + String(repeating: "*", count: value.count - 4) + value.suffix(2)
    }
}

