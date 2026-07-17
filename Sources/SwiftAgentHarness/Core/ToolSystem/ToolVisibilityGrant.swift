import Foundation

/// Registration-time visibility policy for a tool provider or MCP server.
///
/// - ``inheritModeLists``: tools must appear on the authored mode `tools.allow` list (no registration-time widening).
/// - ``grant(modes:)``: requires dual opt-in with ``ResolvedModeProfile/allowsHostGrants``. Together they mean
///   **the host may co-author that mode's allow list** — matching names are unioned into mode-allow before
///   evaluation. Grants are **not** a separate intersecting policy scope and do not rescue a tool after a
///   mode-allow miss. After co-authorship, deny / routing / other scopes still intersect as usual.
public enum ToolVisibilityGrant: Sendable, Equatable {
    case inheritModeLists
    case grant(modes: ToolVisibilityGrantModes)
}

/// Which mode profiles a ``ToolVisibilityGrant/grant(modes:)`` applies to.
public enum ToolVisibilityGrantModes: Sendable, Equatable {
    /// Every profile that opted into host grants (``ResolvedModeProfile/allowsHostGrants`` == `true`).
    ///
    /// Not “every user-facing profile”: with the default `allowsHostGrants = false`, only authored
    /// opt-ins (and inherited explicit opt-ins) receive the grant. Machine profiles never opt in.
    case allOptedIn
    /// Explicit mode profile IDs (e.g. `["plan", "agent"]`). Still requires each listed profile's
    /// ``ResolvedModeProfile/allowsHostGrants`` to be `true` for co-authorship to apply.
    case explicit([String])
}

/// How a grant selects registered tools.
public enum ToolVisibilityGrantMatch: Sendable, Equatable {
    case registrySource(ToolListingSource)
    case toolNames(Set<String>)
    case namePrefix(String)
    /// Matches tools whose registry `groupPolicyTags` contain this tag (e.g. `"plugins"`).
    case groupPolicyTag(String)
}

/// One grant registration (MCP manager, host tool provider install, etc.).
public struct ToolVisibilityGrantRecord: Sendable, Equatable {
    public let id: String
    public let grant: ToolVisibilityGrant
    public let match: ToolVisibilityGrantMatch

    public init(id: String, grant: ToolVisibilityGrant, match: ToolVisibilityGrantMatch) {
        self.id = id
        self.grant = grant
        self.match = match
    }
}

/// Immutable snapshot used during availability / call-gating evaluation.
public struct ToolVisibilityGrantTable: Sendable, Equatable {
    public var records: [ToolVisibilityGrantRecord]

    public static let empty = ToolVisibilityGrantTable(records: [])

    public init(records: [ToolVisibilityGrantRecord] = []) {
        self.records = records
    }

    /// True when a matching `.grant` should co-author this entry's name into the mode-allow list.
    func contributesAllowEntry(entry: ToolRegistryEntry, profile: ResolvedModeProfile) -> Bool {
        guard profile.allowsHostGrants else { return false }
        for record in records {
            guard matches(record.match, entry: entry) else { continue }
            guard case .grant(let modes) = record.grant else { continue }
            if modesCover(modes, profileID: profile.id) {
                return true
            }
        }
        return false
    }

    /// Non-inherit grants whose match covers the entry (regardless of mode / allowsHostGrants).
    func matchingGrantRecords(for entry: ToolRegistryEntry) -> [ToolVisibilityGrantRecord] {
        records.filter { record in
            guard case .grant = record.grant else { return false }
            return matches(record.match, entry: entry)
        }
    }

    /// Unions grant-contributed bare names into an authored allow list (mode-allow co-authorship).
    ///
    /// Dual opt-in (``.grant`` + ``allowsHostGrants``) invites the host to widen this mode's allow membership —
    /// the same moral act as writing a glob into config. It is **not** a cross-scope union or a second
    /// intersecting availability scope. Open world (`nil`) is unchanged. Closed worlds (`[]` or non-empty)
    /// receive the entry name when ``contributesAllowEntry(entry:profile:)`` is true. Afterward, deny and
    /// other scopes still intersect.
    func effectiveAllowList(
        authored: [String]?,
        entry: ToolRegistryEntry,
        profile: ResolvedModeProfile
    ) -> [String]? {
        guard let authored else { return nil }
        guard contributesAllowEntry(entry: entry, profile: profile) else { return authored }
        if authored.contains(entry.name) { return authored }
        return authored + [entry.name]
    }

    private func matches(_ match: ToolVisibilityGrantMatch, entry: ToolRegistryEntry) -> Bool {
        switch match {
        case .registrySource(let source):
            return entry.source == source
        case .toolNames(let names):
            if names.contains(entry.name) { return true }
            let lower = entry.name.lowercased()
            return names.contains { $0.lowercased() == lower }
        case .namePrefix(let prefix):
            return entry.name.hasPrefix(prefix)
        case .groupPolicyTag(let tag):
            return entry.groupPolicyTags.contains(tag)
        }
    }

    private func modesCover(_ modes: ToolVisibilityGrantModes, profileID: String) -> Bool {
        switch modes {
        case .allOptedIn:
            return true
        case .explicit(let ids):
            return ids.contains(profileID)
        }
    }
}

/// Shared mutable registry for host visibility grants (session-scoped).
///
/// `@unchecked Sendable` because mutations are serialized by ``lock``; readers take a value snapshot
/// via ``snapshot()`` for use in concurrent gateway evaluation.
public final class ToolVisibilityGrantStore: @unchecked Sendable {
    public static let mcpRegistrationID = "mcp"
    public static let hostProvidersRegistrationID = "host-providers"

    private let lock = NSLock()
    private var recordsByID: [String: ToolVisibilityGrantRecord] = [:]

    public init() {}

    public func register(_ record: ToolVisibilityGrantRecord) {
        lock.lock()
        defer { lock.unlock() }
        recordsByID[record.id] = record
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        recordsByID.removeValue(forKey: id)
    }

    public func snapshot() -> ToolVisibilityGrantTable {
        lock.lock()
        defer { lock.unlock() }
        return ToolVisibilityGrantTable(records: Array(recordsByID.values))
    }
}
