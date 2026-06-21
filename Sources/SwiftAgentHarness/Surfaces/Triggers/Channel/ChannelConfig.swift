import Foundation

enum ChannelTransportKind: String, Codable, Sendable, Equatable {
    case mock
}

struct ChannelAuthConfig: Codable, Sendable, Equatable {
    var dmAllowFrom: [String] = []
    var groupAllowFrom: [String] = []
    var fallbackGroupToDM: Bool = false

    enum CodingKeys: String, CodingKey {
        case dmAllowFrom = "dm_allow_from"
        case groupAllowFrom = "group_allow_from"
        case fallbackGroupToDM = "fallback_group_to_dm"
    }
}

struct ChannelMentionConfig: Codable, Sendable, Equatable {
    var requireInGroups: Bool = true
    var implicitKinds: [ChannelImplicitMentionKind] = [.replyToBot, .botThreadParticipant]
    var treatUnknownAs: ChannelTreatUnknownMentionAs = .noMention
    var mentionedThreadMaxEntries: Int = BoundedLRUCacheDefaults.mentionedThreadMaxEntries
    var mentionedThreadTTLSeconds: TimeInterval = BoundedLRUCacheDefaults.mentionedThreadTTLSeconds

    enum CodingKeys: String, CodingKey {
        case requireInGroups = "require_in_groups"
        case implicitKinds = "implicit_kinds"
        case treatUnknownAs = "treat_unknown_as"
        case mentionedThreadMaxEntries = "mentioned_thread_max_entries"
        case mentionedThreadTTLSeconds = "mentioned_thread_ttl_seconds"
    }
}

struct ChannelDebounceConfig: Codable, Sendable, Equatable {
    var textMs: Int = 1500

    enum CodingKeys: String, CodingKey {
        case textMs = "text_ms"
    }
}

struct ChannelMediaConfig: Codable, Sendable, Equatable {
    var cacheDir: String?
}

struct ChannelAckConfig: Codable, Sendable, Equatable {
    var reactionScope: String = "group-mentions"
}

enum ChannelDMScope: String, Codable, Sendable, Equatable {
    case main
    case perPeer = "per-peer"
    case perChannelPeer = "per-channel-peer"
    case perAccountChannelPeer = "per-account-channel-peer"
}

struct ChannelListenerConfig: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var transport: ChannelTransportKind = .mock
    var platformIdentity: String = "mock-bot"
    var primaryUser: String = ""
    var auth: ChannelAuthConfig = ChannelAuthConfig()
    var mention: ChannelMentionConfig = ChannelMentionConfig()
    var debounce: ChannelDebounceConfig = ChannelDebounceConfig()
    var media: ChannelMediaConfig = ChannelMediaConfig()
    var ack: ChannelAckConfig = ChannelAckConfig()
    var routingMode: TriggerRoutingMode = .isolated
    var delegate: TriggerDelegateProfile?
    var dmScope: ChannelDMScope = .perChannelPeer
    var identityLinks: [String: String] = [:]
    var includeKnownPartySecurityPreamble: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case transport
        case platformIdentity = "platform_identity"
        case primaryUser = "primary_user"
        case auth
        case mention
        case debounce
        case media
        case ack
        case routingMode = "routing_mode"
        case delegate
        case dmScope = "dm_scope"
        case identityLinks = "identity_links"
        case includeKnownPartySecurityPreamble = "include_known_party_security_preamble"
    }
}

struct ChannelsFile: Codable, Sendable, Equatable {
    var channels: [String: ChannelListenerConfig] = [:]

    func config(for channel: ChannelId) -> ChannelListenerConfig? {
        channels[channel.rawValue]
    }
}

enum ChannelConfigLoader {
    static func load(from url: URL) -> ChannelsFile {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ChannelsFile.self, from: data) else {
            return ChannelsFile()
        }
        return file
    }
}
