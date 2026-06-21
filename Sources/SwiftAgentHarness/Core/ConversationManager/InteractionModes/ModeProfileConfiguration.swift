import EasyJSON
import Foundation

/// Config-driven mode profiles loaded from PromptConfig (`modeProfiles`).
struct ModeProfileConfiguration: Sendable {
    struct RawProfile: Sendable {
        let id: String
        let extends: String?
        let interactionMode: InteractionMode?
        let assemblyKind: SystemPromptAssemblyKind?
        let allowsProactiveCompactionTriggers: Bool?
        let appliesAgentBuildOrchestratorHarness: Bool?
        let semanticLayerTags: [String]?
        let label: String?
        let profileDescription: String?
        let symbol: String?
        /// Partial JSON objects merged onto parent slices (nil → inherit entire parent slice).
        let tools: JSON?
        let skills: JSON?
        let context: JSON?
        let runtime: JSON?
        let model: JSON?
        let subAgents: JSON?
        let hooks: JSON?
    }

    let profiles: [RawProfile]
    let diagnostics: [String]

    static let empty = ModeProfileConfiguration(profiles: [], diagnostics: [])

    static func loadFromPromptConfigBundle() -> ModeProfileConfiguration {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSON.self, from: data),
              case .object(let json) = root,
              let modeProfiles = json["modeProfiles"]
        else {
            return .empty
        }
        return load(fromJSONRoot: modeProfiles)
    }

    /// Loads mode profiles from a project directory (`*.json` files).
    /// Each file can be either a single profile object, a profile array, or `{ "profiles": [...] }`.
    static func loadFromDirectory(_ directoryURL: URL) -> ModeProfileConfiguration {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }
        let jsonFiles = children
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !jsonFiles.isEmpty else {
            return .empty
        }

        var seenIDs = Set<String>()
        var diagnostics: [String] = []
        var profiles: [RawProfile] = []

        for fileURL in jsonFiles {
            guard let data = try? Data(contentsOf: fileURL) else {
                diagnostics.append("modeProfiles failed reading '\(fileURL.lastPathComponent)'")
                continue
            }
            guard let root = try? JSONDecoder().decode(JSON.self, from: data) else {
                diagnostics.append("modeProfiles invalid JSON in '\(fileURL.lastPathComponent)'")
                continue
            }
            let rows = profileRows(from: root)
            if rows.isEmpty {
                diagnostics.append("modeProfiles no profile rows in '\(fileURL.lastPathComponent)'")
            }
            parseProfileRows(rows, seenIDs: &seenIDs, diagnostics: &diagnostics, output: &profiles)
        }
        return ModeProfileConfiguration(profiles: profiles, diagnostics: diagnostics)
    }

    private static func load(fromJSONRoot root: JSON) -> ModeProfileConfiguration {
        let rows = profileRows(from: root)
        if rows.isEmpty {
            return .empty
        }
        var seenIDs = Set<String>()
        var diagnostics: [String] = []
        var profiles: [RawProfile] = []
        parseProfileRows(rows, seenIDs: &seenIDs, diagnostics: &diagnostics, output: &profiles)
        return ModeProfileConfiguration(profiles: profiles, diagnostics: diagnostics)
    }

    private static func profileRows(from root: JSON) -> [[String: JSON]] {
        switch root {
        case .object(let dict):
            if case .array(let profiles)? = dict["profiles"] {
                return profiles.compactMap(\.objectFields)
            }
            return [dict]
        case .array(let rows):
            return rows.compactMap(\.objectFields)
        default:
            return []
        }
    }

    private static func parseProfileRows(
        _ rows: [[String: JSON]],
        seenIDs: inout Set<String>,
        diagnostics: inout [String],
        output profiles: inout [RawProfile]
    ) {
        for profile in rows {
            guard let idRaw = profile.optionalString(for: "id") else {
                diagnostics.append("modeProfiles entry missing id")
                continue
            }
            let id = idRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                diagnostics.append("modeProfiles entry has empty id")
                continue
            }
            guard seenIDs.insert(id).inserted else {
                diagnostics.append("modeProfiles duplicate id '\(id)'")
                continue
            }

            let extends = profile.optionalString(for: "extends")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            let interactionMode: InteractionMode? = {
                guard let raw = profile.optionalString(for: "interactionMode") else { return nil }
                let parsed = InteractionMode(rawValue: raw)
                if parsed == nil {
                    diagnostics.append("modeProfiles[\(id)] invalid interactionMode")
                }
                return parsed
            }()

            let assemblyKind: SystemPromptAssemblyKind?
            if let raw = profile.optionalString(for: "assemblyKind") {
                assemblyKind = SystemPromptAssemblyKind(rawValue: raw)
                if assemblyKind == nil {
                    diagnostics.append("modeProfiles[\(id)] invalid assemblyKind")
                }
            } else {
                assemblyKind = nil
            }

            if extends == nil {
                guard let interactionMode,
                      let assemblyKind
                else {
                    diagnostics.append("modeProfiles[\(id)] requires interactionMode and assemblyKind when extends is omitted")
                    continue
                }
                guard Self.isAllowedCombination(interactionMode: interactionMode, assemblyKind: assemblyKind) else {
                    diagnostics.append("modeProfiles[\(id)] disallowed interactionMode/assemblyKind combination")
                    continue
                }
            } else {
                if let interactionMode, let assemblyKind,
                   !Self.isAllowedCombination(interactionMode: interactionMode, assemblyKind: assemblyKind) {
                    diagnostics.append("modeProfiles[\(id)] disallowed interactionMode/assemblyKind combination")
                    continue
                }
            }

            let allowsProactiveCompactionTriggers = profile.optionalBool(for: "allowsProactiveCompactionTriggers")
            let appliesAgentBuildOrchestratorHarness = profile.optionalBool(for: "appliesAgentBuildOrchestratorHarness")
            let semanticLayerTags = ModeProfileJSONParsing.normalizedStringArray(from: profile["semanticLayerTags"])

            let label = profile.optionalString(for: "label")
            let profileDescription = profile.optionalString(for: "description")
            let symbol = profile.optionalString(for: "symbol")

            profiles.append(
                RawProfile(
                    id: id,
                    extends: extends,
                    interactionMode: interactionMode,
                    assemblyKind: assemblyKind,
                    allowsProactiveCompactionTriggers: allowsProactiveCompactionTriggers,
                    appliesAgentBuildOrchestratorHarness: appliesAgentBuildOrchestratorHarness,
                    semanticLayerTags: semanticLayerTags,
                    label: label,
                    profileDescription: profileDescription,
                    symbol: symbol,
                    tools: profile["tools"],
                    skills: profile["skills"],
                    context: profile["context"],
                    runtime: profile["runtime"],
                    model: profile["model"],
                    subAgents: profile["subAgents"],
                    hooks: profile["hooks"]
                )
            )
        }
    }

    private static func isAllowedCombination(interactionMode: InteractionMode, assemblyKind: SystemPromptAssemblyKind) -> Bool {
        switch interactionMode {
        case .chat:
            return assemblyKind == .chat
        case .plan:
            return assemblyKind == .planCollaboration
        case .agent:
            return assemblyKind == .agentBuild
        }
    }
}

extension ModeProfileConfiguration.RawProfile {
    /// Profile row that only overlays slices on an ``extends`` parent (JSON shape when interaction fields are inherited).
    init(
        id: String,
        extends: String,
        tools: JSON? = nil,
        skills: JSON? = nil,
        context: JSON? = nil,
        runtime: JSON? = nil,
        model: JSON? = nil,
        subAgents: JSON? = nil,
        hooks: JSON? = nil
    ) {
        self.id = id
        self.extends = extends
        self.interactionMode = nil
        self.assemblyKind = nil
        self.allowsProactiveCompactionTriggers = nil
        self.appliesAgentBuildOrchestratorHarness = nil
        self.semanticLayerTags = nil
        self.label = nil
        self.profileDescription = nil
        self.symbol = nil
        self.tools = tools
        self.skills = skills
        self.context = context
        self.runtime = runtime
        self.model = model
        self.subAgents = subAgents
        self.hooks = hooks
    }

    /// Compact initializer for tests and programmatic construction (JSON parsing uses memberwise paths).
    init(
        id: String,
        interactionMode: InteractionMode,
        assemblyKind: SystemPromptAssemblyKind,
        allowsProactiveCompactionTriggers: Bool,
        appliesAgentBuildOrchestratorHarness: Bool,
        semanticLayerTags: [String],
        extends: String? = nil,
        label: String? = nil,
        profileDescription: String? = nil,
        symbol: String? = nil,
        tools: JSON? = nil,
        skills: JSON? = nil,
        context: JSON? = nil,
        runtime: JSON? = nil,
        model: JSON? = nil,
        subAgents: JSON? = nil,
        hooks: JSON? = nil
    ) {
        self.id = id
        self.extends = extends
        self.interactionMode = interactionMode
        self.assemblyKind = assemblyKind
        self.allowsProactiveCompactionTriggers = allowsProactiveCompactionTriggers
        self.appliesAgentBuildOrchestratorHarness = appliesAgentBuildOrchestratorHarness
        self.semanticLayerTags = semanticLayerTags
        self.label = label
        self.profileDescription = profileDescription
        self.symbol = symbol
        self.tools = tools
        self.skills = skills
        self.context = context
        self.runtime = runtime
        self.model = model
        self.subAgents = subAgents
        self.hooks = hooks
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
