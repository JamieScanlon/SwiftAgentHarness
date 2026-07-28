import Foundation
import Logging

/// Naming rules for delegate tools generated from operator-authored local-agent definitions.
///
/// The `delegate_` prefix is load-bearing: `DefaultSubAgentPool.isDelegateTool`,
/// `DefaultSubAgentPool.isOpaqueDelegateToolHandle`, `ToolRegistryResultFormattingPolicy` and
/// `ToolRegistryEntry.augmentedPolicyTags` all classify on it. Generating names that satisfy the
/// existing convention avoids introducing a second delegate-recognition mechanism.
public enum LocalAgentToolNaming {
    public static let delegateToolPrefix = "delegate_"

    /// `"Coding Agent"` -> `"delegate_coding_agent"`. Returns `nil` when the key has no usable slug.
    public static func delegateToolName(forConfigKey key: String) -> String? {
        let slug = slugify(key)
        guard !slug.isEmpty else { return nil }
        guard !slug.hasPrefix(delegateToolPrefix) else { return slug }
        return delegateToolPrefix + slug
    }

    /// Lowercased ASCII `[a-z0-9_]`, runs of separators collapsed, no leading/trailing separator.
    static func slugify(_ raw: String) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty {
                    slug.append("_")
                }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return slug
    }
}

/// One operator-declared, in-process sub-agent published to the model as a `delegate_*` tool.
///
/// Transport-neutral by design: a future Markdown + frontmatter loader can populate the same shape
/// without a second registry path (see `SPEC_DIVERGENCES.md`, DIV-001).
public struct LocalAgentDefinition: Sendable, Equatable {
    /// Generated delegate tool name (`delegate_` + slugified config key).
    public var toolName: String
    /// Config key as authored; used for lifecycle/UI labels.
    public var displayName: String
    /// Model-facing description of what this agent does.
    public var description: String
    /// Mode profile assigned to the spawned child. Existence is verified against the mode registry
    /// at provider-install time; an unresolvable id means the delegate is not published at all.
    public var modeProfileID: String
    /// Model the child runs on. `nil` inherits the parent conversation's model — the template's
    /// `model: 'inherit'`, and the only portable default in a model-agnostic harness.
    public var modelRef: String?
    /// Closed-world tool allow list applied to the child. `nil` defers to the child's mode profile.
    public var toolsAllow: [String]?
    /// Reserved for push-based completion delivery. The in-process path is synchronous today and
    /// must not read long-running-ness from transport capabilities, which always report `true`.
    public var longRunning: Bool
    /// Wall-clock budget for a blocking delegate run.
    public var runTimeoutSeconds: TimeInterval
    /// Per-agent recursion cap, combined with mode-profile and transport caps at launch time.
    public var maxRecursionDepth: Int?

    public init(
        toolName: String,
        displayName: String,
        description: String,
        modeProfileID: String,
        modelRef: String? = nil,
        toolsAllow: [String]? = nil,
        longRunning: Bool = false,
        runTimeoutSeconds: TimeInterval = LocalAgentConfiguration.defaultRunTimeoutSeconds,
        maxRecursionDepth: Int? = nil
    ) {
        self.toolName = toolName
        self.displayName = displayName
        self.description = description
        self.modeProfileID = modeProfileID
        self.modelRef = modelRef
        self.toolsAllow = toolsAllow
        self.longRunning = longRunning
        self.runTimeoutSeconds = runTimeoutSeconds
        self.maxRecursionDepth = maxRecursionDepth
    }
}

/// Parsed `localAgents` PromptConfig section.
public struct LocalAgentConfiguration: Sendable, Equatable {
    public static let defaultRunTimeoutSeconds: TimeInterval = 300
    public static let maximumRunTimeoutSeconds: TimeInterval = 3600

    public var definitionsByToolName: [String: LocalAgentDefinition]
    /// Human-readable rejection reasons, one per skipped entry. Surfaced by the composition root.
    public var diagnostics: [String]

    /// Explicitly no local agents. Distinct from the default, which seeds the built-in roles.
    public static let empty = LocalAgentConfiguration(definitionsByToolName: [:], diagnostics: [])

    /// The built-in delegate roles, seeded whenever the harness is not told otherwise.
    public static let builtInDefaults = LocalAgentConfiguration(
        definitionsByToolName: Dictionary(
            uniqueKeysWithValues: LocalAgentBuiltInCatalog.all().map { ($0.toolName, $0) }
        )
    )

    public init(definitionsByToolName: [String: LocalAgentDefinition], diagnostics: [String] = []) {
        self.definitionsByToolName = definitionsByToolName
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { definitionsByToolName.isEmpty }

    /// Deterministic order for tool publication and prompt listing.
    public var definitions: [LocalAgentDefinition] {
        definitionsByToolName.values.sorted { $0.toolName < $1.toolName }
    }

    public func definition(forToolName toolName: String) -> LocalAgentDefinition? {
        if let exact = definitionsByToolName[toolName] { return exact }
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return definitionsByToolName.first { $0.key.lowercased() == normalized }?.value
    }

    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> LocalAgentConfiguration {
        guard let json = document.foundationRoot() else {
            return .builtInDefaults
        }
        return fromPromptConfigRoot(json, logger: logger)
    }

    /// Built-ins seed the registry; a config row whose slugified key matches a built-in tool name
    /// replaces it outright, mirroring how `modeProfiles` overlays built-in profiles by id.
    static func fromPromptConfigRoot(_ json: [String: Any], logger: Logger? = nil) -> LocalAgentConfiguration {
        guard let raw = json["localAgents"] as? [String: Any] else {
            return .builtInDefaults
        }
        var definitions = builtInDefaults.definitionsByToolName
        var diagnostics: [String] = []
        var claimedBy: [String: String] = [:]

        for configKey in raw.keys.sorted() {
            guard let entry = raw[configKey] as? [String: Any] else {
                diagnostics.append("localAgents['\(configKey)']: entry is not an object")
                continue
            }
            guard let toolName = LocalAgentToolNaming.delegateToolName(forConfigKey: configKey) else {
                diagnostics.append("localAgents['\(configKey)']: name has no usable ASCII slug")
                continue
            }
            if let owner = claimedBy[toolName] {  // two config keys slugifying to one tool name
                diagnostics.append(
                    "localAgents['\(configKey)']: tool name '\(toolName)' already claimed by '\(owner)'"
                )
                continue
            }
            guard let description = nonEmptyString(entry["description"]) else {
                diagnostics.append("localAgents['\(configKey)']: missing or empty 'description'")
                continue
            }
            guard let modeProfileID = nonEmptyString(entry["modeProfileId"]) else {
                diagnostics.append("localAgents['\(configKey)']: missing or empty 'modeProfileId'")
                continue
            }
            let modelRef = nonEmptyString(entry["modelRef"])

            // Fail closed: a present-but-malformed allow list must never widen to "all tools".
            var toolsAllow: [String]?
            if let rawToolsAllow = entry["toolsAllow"] {
                guard let list = rawToolsAllow as? [Any] else {
                    diagnostics.append("localAgents['\(configKey)']: 'toolsAllow' must be an array of strings")
                    continue
                }
                let names = list.compactMap { nonEmptyString($0) }
                guard names.count == list.count else {
                    diagnostics.append("localAgents['\(configKey)']: 'toolsAllow' contains a non-string entry")
                    continue
                }
                toolsAllow = names
            }

            var maxRecursionDepth: Int?
            if let rawDepth = entry["maxRecursionDepth"] {
                guard let depth = (rawDepth as? NSNumber)?.intValue, depth >= 0 else {
                    diagnostics.append("localAgents['\(configKey)']: 'maxRecursionDepth' must be a non-negative integer")
                    continue
                }
                maxRecursionDepth = depth
            }

            var runTimeoutSeconds = defaultRunTimeoutSeconds
            if let rawTimeout = entry["runTimeoutSeconds"] {
                guard let seconds = (rawTimeout as? NSNumber)?.doubleValue, seconds > 0 else {
                    diagnostics.append("localAgents['\(configKey)']: 'runTimeoutSeconds' must be a positive number")
                    continue
                }
                runTimeoutSeconds = min(seconds, maximumRunTimeoutSeconds)
            }

            claimedBy[toolName] = configKey
            definitions[toolName] = LocalAgentDefinition(
                toolName: toolName,
                displayName: configKey,
                description: description,
                modeProfileID: modeProfileID,
                modelRef: modelRef,
                toolsAllow: toolsAllow,
                longRunning: (entry["longRunning"] as? NSNumber)?.boolValue ?? false,
                runTimeoutSeconds: runTimeoutSeconds,
                maxRecursionDepth: maxRecursionDepth
            )
        }

        for diagnostic in diagnostics {
            logger?.warning("\(diagnostic)")
        }
        return LocalAgentConfiguration(definitionsByToolName: definitions, diagnostics: diagnostics)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
