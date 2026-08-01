import Foundation

/// `CaseIterable` is load-bearing, not cosmetic: the listener registry and the config loader both
/// need to enumerate every channel, and both used to carry their own hand-written list. A fifth
/// channel added to this enum would have been silently skipped by whichever list nobody updated.
public enum ChannelId: String, Sendable, Codable, CaseIterable {
    case slack
    case telegram
    case discord
    case email
}
