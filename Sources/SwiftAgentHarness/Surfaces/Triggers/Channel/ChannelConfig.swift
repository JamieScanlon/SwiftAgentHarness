import Foundation

enum ChannelTransportKind: String, Codable, Sendable, Equatable {
    case mock
    case slack
    case telegram
    case discord
    case email
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

struct ChannelDedupeConfig: Codable, Sendable, Equatable {
    var ttlSeconds: Int = 3600

    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}

/// Not consumed yet. `ChannelListenerRegistry` computes its media root from `dataDirectory`, so an
/// operator setting `cache_dir` today is ignored — the field is a placeholder for the real transport
/// adapters, alongside `ChannelAckConfig`.
///
/// The explicit `CodingKeys` is the point of this being written out rather than synthesized. Every
/// other config type in this file spells its keys in snake_case; `ChannelMediaConfig` and
/// `ChannelAckConfig` were the two that did not, and the missing `CodingKeys` on the latter is what
/// broke the build when a decoder referenced `.reactionScope`. Renaming a field nothing reads is
/// free exactly once — now.
struct ChannelMediaConfig: Codable, Sendable, Equatable {
    var cacheDir: String?

    enum CodingKeys: String, CodingKey {
        case cacheDir = "cache_dir"
    }
}

/// Not consumed yet — see ``ChannelMediaConfig``. Nothing reads `reactionScope`, which is why the
/// `reaction_scope` key could be corrected without a migration.
struct ChannelAckConfig: Codable, Sendable, Equatable {
    var reactionScope: String = "group-mentions"

    enum CodingKeys: String, CodingKey {
        case reactionScope = "reaction_scope"
    }
}

enum ChannelStreamingPreset: String, Codable, Sendable, Equatable {
    case social
    case `operator`
    case finalOnly = "final_only"
}

struct ChannelStreamingConfig: Codable, Sendable, Equatable {
    var preset: ChannelStreamingPreset = .social
    var textChunkLimit: Int = 4000

    enum CodingKeys: String, CodingKey {
        case preset
        case textChunkLimit = "text_chunk_limit"
    }
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
    var dedupe: ChannelDedupeConfig = ChannelDedupeConfig()
    var media: ChannelMediaConfig = ChannelMediaConfig()
    var ack: ChannelAckConfig = ChannelAckConfig()
    var streaming: ChannelStreamingConfig = ChannelStreamingConfig()
    var routingMode: TriggerRoutingMode = .isolated
    var delegate: TriggerDelegateProfile?
    var dmScope: ChannelDMScope = .perChannelPeer
    var identityLinks: [String: String] = [:]
    var includeKnownPartySecurityPreamble: Bool = true
    /// Registration ownership for this channel, in the tenancy/tool layer's units.
    ///
    /// Deliberately *not* merged with ``primaryUser``: they answer different questions and are not
    /// interchangeable. `primaryUser` is a platform sender-id string that decides `user-direct`
    /// trust for inbound messages (see `ChannelTrustClassifier`); this is the harness account that
    /// owns the channel registration, and it is what a lifecycle mutation is checked against.
    /// Merging them would make a Slack handle an authorization principal.
    ///
    /// `nil` means "no owner recorded" — single-tenant deployments leave it unset, and the
    /// lifecycle check then falls back to creator class alone.
    var ownerAccountID: UUID?

    enum CodingKeys: String, CodingKey {
        case enabled
        case transport
        case platformIdentity = "platform_identity"
        case primaryUser = "primary_user"
        case auth
        case mention
        case debounce
        case dedupe
        case media
        case ack
        case streaming
        case routingMode = "routing_mode"
        case delegate
        case dmScope = "dm_scope"
        case identityLinks = "identity_links"
        case includeKnownPartySecurityPreamble = "include_known_party_security_preamble"
        case ownerAccountID = "owner_account_id"
    }
}

struct ChannelsFile: Codable, Sendable, Equatable {
    var channels: [String: ChannelListenerConfig] = [:]

    func config(for channel: ChannelId) -> ChannelListenerConfig? {
        channels[channel.rawValue]
    }
}

/// Why a channel configuration did not load the way the operator meant it to.
enum ChannelConfigDiagnostic: Sendable, Equatable {
    /// No file at all. Routine for a deployment with no channels — reported at debug, not error.
    case fileMissing(path: String)
    case unreadable(path: String, message: String)
    case malformed(path: String, message: String)
    /// A key under `channels` that is not a known channel id. A `"slak"` typo would otherwise mean
    /// the channel silently never appears, with the file itself looking perfectly valid.
    case unknownChannelKey(String)

    var isFailure: Bool {
        switch self {
        case .fileMissing: return false
        case .unreadable, .malformed, .unknownChannelKey: return true
        }
    }

    var message: String {
        switch self {
        case .fileMissing(let path):
            return "channel_config_absent path=\(path)"
        case .unreadable(let path, let message):
            return "channel_config_unreadable path=\(path) error=\(message)"
        case .malformed(let path, let message):
            return "channel_config_malformed path=\(path) error=\(message)"
        case .unknownChannelKey(let key):
            return "channel_config_unknown_channel key=\(key)"
        }
    }
}

struct ChannelConfigLoadResult: Sendable {
    var file: ChannelsFile
    var diagnostics: [ChannelConfigDiagnostic]
    /// Whether `file` is what the operator's JSON actually says.
    ///
    /// This is what per-channel decisions and drift detection gate on — deliberately *not* "were
    /// there any diagnostics". An unknown-channel typo is a real failure worth shouting about, but
    /// the rest of the file parsed perfectly; gating on the diagnostics list would let one typo
    /// silently switch off reporting for every other channel. Only whole-file failures (unreadable,
    /// malformed) make the contents untrustworthy.
    var decodedCleanly: Bool
}

enum ChannelConfigLoader {
    static func loadResult(from url: URL) -> ChannelConfigLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // An absent file *is* a clean decode of "no channels": deleting `channels.json` is the
            // most emphatic way an operator has of turning everything off, and it must reconcile the
            // same way at runtime as it does at boot.
            return ChannelConfigLoadResult(
                file: ChannelsFile(),
                diagnostics: [.fileMissing(path: url.path)],
                decodedCleanly: true
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ChannelConfigLoadResult(
                file: ChannelsFile(),
                diagnostics: [.unreadable(path: url.path, message: String(describing: error))],
                decodedCleanly: false
            )
        }
        let file: ChannelsFile
        do {
            file = try JSONDecoder().decode(ChannelsFile.self, from: data)
        } catch {
            return ChannelConfigLoadResult(
                file: ChannelsFile(),
                diagnostics: [.malformed(path: url.path, message: String(describing: error))],
                decodedCleanly: false
            )
        }
        let known = Set(ChannelId.allCases.map(\.rawValue))
        let diagnostics = file.channels.keys
            .filter { !known.contains($0) }
            .sorted()
            .map { ChannelConfigDiagnostic.unknownChannelKey($0) }
        return ChannelConfigLoadResult(file: file, diagnostics: diagnostics, decodedCleanly: true)
    }
}
