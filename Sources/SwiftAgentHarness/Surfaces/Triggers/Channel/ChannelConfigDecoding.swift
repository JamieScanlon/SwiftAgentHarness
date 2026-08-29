import Foundation

// Lenient decoders for every `channels.json` shape.
//
// Swift's *synthesized* `init(from:)` emits `decode(_:forKey:)` for each non-Optional property and
// ignores the property's default value — only Optionals get `decodeIfPresent`. So a config written
// the way the README documents it:
//
//     { "channels": { "slack": { "enabled": true } } }
//
// threw `keyNotFound(.transport)`, and the *whole file* failed to decode. Before the lifecycle work
// that failed silently: `ChannelConfigLoader` returned an empty `ChannelsFile` and every channel was
// off with no log line. It is louder now — `channel_config_malformed`, and
// `channel_config_unreadable` on every lifecycle mutation — which is how it was found, but louder is
// not fixed. An operator writing a partial config is the normal case, not a malformed one.
//
// Each decoder below is written in an **extension** on purpose: declaring `init(from:)` inside the
// struct body would suppress the memberwise initializer, and these types are constructed positionally
// at ~45 sites across Sources and Tests.
//
// Enum-typed fields go through `try?` so a value written by a newer build degrades to the default
// rather than failing the file — the same forward-compatibility rule `ScheduledTask.init(from:)`
// follows. `nil` and "unrecognised" are treated alike here because both mean "this build has no
// opinion", and a config that stops loading on upgrade-then-downgrade is worse than one that falls
// back to a documented default.

private extension KeyedDecodingContainer {
    /// `decodeIfPresent`, with an unrecognised value treated as absent.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }
}

extension ChannelAuthConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        dmAllowFrom = container.lenient([String].self, .dmAllowFrom, default: dmAllowFrom)
        groupAllowFrom = container.lenient([String].self, .groupAllowFrom, default: groupAllowFrom)
        fallbackGroupToDM = container.lenient(Bool.self, .fallbackGroupToDM, default: fallbackGroupToDM)
    }
}

extension ChannelMentionConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        requireInGroups = container.lenient(Bool.self, .requireInGroups, default: requireInGroups)
        implicitKinds = container.lenient([ChannelImplicitMentionKind].self, .implicitKinds, default: implicitKinds)
        treatUnknownAs = container.lenient(ChannelTreatUnknownMentionAs.self, .treatUnknownAs, default: treatUnknownAs)
        mentionedThreadMaxEntries = container.lenient(
            Int.self, .mentionedThreadMaxEntries, default: mentionedThreadMaxEntries
        )
        mentionedThreadTTLSeconds = container.lenient(
            TimeInterval.self, .mentionedThreadTTLSeconds, default: mentionedThreadTTLSeconds
        )
    }
}

extension ChannelDebounceConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        textMs = container.lenient(Int.self, .textMs, default: textMs)
    }
}

extension ChannelDedupeConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        ttlSeconds = container.lenient(Int.self, .ttlSeconds, default: ttlSeconds)
    }
}

extension ChannelAckConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        reactionScope = container.lenient(String.self, .reactionScope, default: reactionScope)
    }
}

extension ChannelStreamingConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        preset = container.lenient(ChannelStreamingPreset.self, .preset, default: preset)
        textChunkLimit = container.lenient(Int.self, .textChunkLimit, default: textChunkLimit)
    }
}

extension ChannelListenerConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = container.lenient(Bool.self, .enabled, default: enabled)
        transport = container.lenient(ChannelTransportKind.self, .transport, default: transport)
        platformIdentity = container.lenient(String.self, .platformIdentity, default: platformIdentity)
        primaryUser = container.lenient(String.self, .primaryUser, default: primaryUser)
        auth = container.lenient(ChannelAuthConfig.self, .auth, default: auth)
        mention = container.lenient(ChannelMentionConfig.self, .mention, default: mention)
        debounce = container.lenient(ChannelDebounceConfig.self, .debounce, default: debounce)
        dedupe = container.lenient(ChannelDedupeConfig.self, .dedupe, default: dedupe)
        media = container.lenient(ChannelMediaConfig.self, .media, default: media)
        ack = container.lenient(ChannelAckConfig.self, .ack, default: ack)
        streaming = container.lenient(ChannelStreamingConfig.self, .streaming, default: streaming)
        routingMode = container.lenient(TriggerRoutingMode.self, .routingMode, default: routingMode)
        delegate = try? container.decodeIfPresent(TriggerDelegateProfile.self, forKey: .delegate)
        dmScope = container.lenient(ChannelDMScope.self, .dmScope, default: dmScope)
        identityLinks = container.lenient([String: String].self, .identityLinks, default: identityLinks)
        includeKnownPartySecurityPreamble = container.lenient(
            Bool.self, .includeKnownPartySecurityPreamble, default: includeKnownPartySecurityPreamble
        )
        // Not `lenient`: a malformed owner id must not silently become "no owner recorded", which is
        // the permissive branch of the lifecycle ownership check.
        ownerAccountID = try container.decodeIfPresent(UUID.self, forKey: .ownerAccountID)
    }
}
