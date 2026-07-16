import Foundation

/// Registration-time visibility policy for a tool provider or MCP server.
///
/// - ``inheritModeLists``: today's behavior — tools must appear on the mode `tools.allow` list.
/// - ``grant(modes:)``: widen visibility into modes that allow host grants (``ResolvedModeProfile/allowsHostGrants``),
///   without editing per-mode allow lists. Mode `tools.deny` still wins.
public enum ToolVisibilityGrant: Sendable, Equatable {
    case inheritModeLists
    case grant(modes: ToolVisibilityGrantModes)
}

/// Which mode profiles a ``ToolVisibilityGrant/grant(modes:)`` applies to.
public enum ToolVisibilityGrantModes: Sendable, Equatable {
    /// Every profile with ``ResolvedModeProfile/allowsHostGrants`` equal to `true`.
    case allUserFacing
    /// Explicit mode profile IDs (e.g. `["plan", "agent"]`).
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

/// Why a matching host visibility grant did not admit a tool for the current profile.
public enum HostVisibilityGrantRejectionCause: String, Sendable, Equatable {
    /// ``ResolvedModeProfile/allowsHostGrants`` is false (explicit opt-out or machine pin).
    case flagDisabled
    /// Grant modes do not cover this profile ID.
    case modesExcludeProfile
    /// Profile's merged `tools.allow` is an authored empty list (derived lockdown).
    case emptyAllowLockdown

    public var explainDetail: String {
        switch self {
        case .flagDisabled:
            return "Profile opts out of host visibility grants (`allowsHostGrants=false`)."
        case .modesExcludeProfile:
            return "A host visibility grant matches this tool, but grant modes exclude this profile."
        case .emptyAllowLockdown:
            return "Profile is an authored lockdown (`tools.allow: []`); host grants are suppressed. Add allow entries or set allowsHostGrants: true to receive them."
        }
    }

    public func fixItConfigKey(profileID: String) -> String {
        switch self {
        case .flagDisabled, .emptyAllowLockdown:
            return "modeProfiles.\(profileID).allowsHostGrants / modeProfiles.\(profileID).tools.allow"
        case .modesExcludeProfile:
            return "setMCPManager(visibilityGrant:) / installAdditionalToolProviders(visibilityGrant:)"
        }
    }
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

    /// True when a non-inherit grant admits this entry for the given profile.
    func admits(entry: ToolRegistryEntry, profile: ResolvedModeProfile) -> Bool {
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

    /// Sub-cause when a matching grant exists but ``admits(entry:profile:)`` is false.
    func rejectionCause(
        for entry: ToolRegistryEntry,
        profile: ResolvedModeProfile
    ) -> HostVisibilityGrantRejectionCause? {
        guard !matchingGrantRecords(for: entry).isEmpty else { return nil }
        guard !admits(entry: entry, profile: profile) else { return nil }
        if profile.allowsHostGrantsSource == .derivedEmptyAllow {
            return .emptyAllowLockdown
        }
        if !profile.allowsHostGrants {
            return .flagDisabled
        }
        return .modesExcludeProfile
    }

    /// Auto-allow rules for the ``host-grant`` gating scope (empty when not admitted).
    func autoAllowRules(
        for entry: ToolRegistryEntry,
        profile: ResolvedModeProfile
    ) -> [ToolPolicyRule] {
        guard admits(entry: entry, profile: profile) else { return [] }
        return [.bareName(entry.name)]
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
        case .allUserFacing:
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
