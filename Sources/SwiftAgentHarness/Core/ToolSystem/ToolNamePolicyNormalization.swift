import Foundation

/// Normalizes tool names for policy matching: trim, lowercase, legacy alias resolution.
///
/// Applied wherever allow/deny lists, persisted grants, and pre-approved sets are evaluated
/// so config and MCP naming drift cannot bypass policy.
///
/// Delegates to ``ToolRegistryNameIndex``; turn-time paths should pass ``RuntimeToolTurnPolicySnapshot.nameIndex``.
enum ToolNamePolicyNormalization {
    /// Trims whitespace and lowercases. Wildcard `*` is preserved as-is.
    static func normalizeToken(_ name: String) -> String {
        ToolRegistryNameIndex.normalizeToken(name)
    }

    /// Normalizes and resolves legacy aliases to canonical registry names.
    static func canonical(_ name: String, index: ToolRegistryNameIndex = .builtIn) -> String {
        index.canonical(name)
    }

    /// Whether `name` matches any entry in `list`, honoring wildcard `*`.
    static func listContains(
        _ list: [String],
        name: String,
        index: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        index.listContains(list, name: name)
    }

    /// Whether `name` matches any entry in `set`, honoring wildcard `*`.
    static func setContains(
        _ set: Set<String>,
        name: String,
        index: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        index.setContains(set, name: name)
    }

    /// Whether a model-emitted tool call name matches a registry entry name.
    static func matchesRegistryName(
        callName: String,
        entryName: String,
        index: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        index.matchesRegistryName(callName: callName, entryName: entryName)
    }

    /// Registry identity for policy matching when a concrete entry is known.
    ///
    /// Legacy aliases (e.g. `search` → `grep`) apply to config tokens and model-emitted
    /// names without a registry entry, but must not remap distinct registered tools.
    static func registryName(_ entry: ToolRegistryEntry, index: ToolRegistryNameIndex = .builtIn) -> String {
        index.registryName(entry)
    }

    /// Name used for policy list matching; prefers registry identity when `entry` is provided.
    static func policyMatchName(
        toolName: String,
        entry: ToolRegistryEntry?,
        index: ToolRegistryNameIndex = .builtIn
    ) -> String {
        index.policyMatchName(toolName: toolName, entry: entry)
    }

    /// Candidate names for policy matching (registry identity, literal name, legacy alias).
    static func policyMatchNames(
        toolName: String,
        entry: ToolRegistryEntry?,
        index: ToolRegistryNameIndex = .builtIn
    ) -> [String] {
        index.policyMatchNames(toolName: toolName, entry: entry)
    }

    /// Normalizes each list entry for storage at config load time.
    static func normalizedPolicyList(_ list: [String], index: ToolRegistryNameIndex = .builtIn) -> [String] {
        index.normalizedPolicyList(list)
    }

    /// Normalizes each set entry for storage at config load time.
    static func normalizedPolicySet(_ set: Set<String>, index: ToolRegistryNameIndex = .builtIn) -> Set<String> {
        index.normalizedPolicySet(set)
    }

    static func resolveEntry(
        named toolName: String,
        in entries: [ToolRegistryEntry],
        index: ToolRegistryNameIndex = .builtIn
    ) -> ToolRegistryEntry? {
        index.resolveEntry(named: toolName, in: entries)
    }
}
