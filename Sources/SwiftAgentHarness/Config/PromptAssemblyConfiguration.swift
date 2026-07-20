import Foundation

/// Prompt-assembly knobs derived from PromptConfig `options`, `settings`, and `lineagePromptSections`.
public struct PromptAssemblyConfiguration: Sendable, Equatable, Codable {
    public var includeCurrentDateTime: Bool
    public var includeAgentSkills: Bool
    public var skillsFolderPath: String?
    public var subAgentContextTemplate: String
    public var assemblyCheckpointMode: SystemPromptAssemblyCheckpointMode
    public var assemblyCheckpointMaxFullTextBytes: Int

    public static let defaultSubAgentContextTemplate = """
You are a sub-agent (depth {{subAgentDepth}}) delegated from root conversation {{subAgentRootConversationID}}. Your conversation ID is {{subAgentConversationID}}. Parent conversation: {{subAgentParentConversationID}}. Work only within this sub-agent thread; do not switch conversations or assume the user's foreground selection.
"""

    public static let `default` = PromptAssemblyConfiguration(
        includeCurrentDateTime: true,
        includeAgentSkills: true,
        skillsFolderPath: nil,
        subAgentContextTemplate: defaultSubAgentContextTemplate,
        assemblyCheckpointMode: .digestOnly,
        assemblyCheckpointMaxFullTextBytes: SystemPromptAssemblyCheckpointConfiguration.defaultMaxFullTextBytes
    )

    public init(
        includeCurrentDateTime: Bool,
        includeAgentSkills: Bool,
        skillsFolderPath: String?,
        subAgentContextTemplate: String,
        assemblyCheckpointMode: SystemPromptAssemblyCheckpointMode,
        assemblyCheckpointMaxFullTextBytes: Int
    ) {
        self.includeCurrentDateTime = includeCurrentDateTime
        self.includeAgentSkills = includeAgentSkills
        self.skillsFolderPath = skillsFolderPath
        self.subAgentContextTemplate = subAgentContextTemplate
        self.assemblyCheckpointMode = assemblyCheckpointMode
        self.assemblyCheckpointMaxFullTextBytes = assemblyCheckpointMaxFullTextBytes
    }

    public static func load(from document: PromptConfigDocument) -> PromptAssemblyConfiguration {
        var config = PromptAssemblyConfiguration.default
        if let options = document.foundationObject(forKey: "options") {
            if let value = options["includeCurrentDateTime"] as? Bool {
                config.includeCurrentDateTime = value
            }
            if let value = options["includeAgentSkills"] as? Bool {
                config.includeAgentSkills = value
            }
            if let checkpoint = options["systemPromptAssemblyCheckpoint"] as? [String: Any] {
                let modeRaw = (checkpoint["mode"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                config.assemblyCheckpointMode = switch modeRaw {
                case "off": .off
                case "fulltext", "full_text", "full": .fullText
                default: .digestOnly
                }
                let maxBytes = checkpoint["maxFullTextBytes"] as? Int
                    ?? SystemPromptAssemblyCheckpointConfiguration.defaultMaxFullTextBytes
                config.assemblyCheckpointMaxFullTextBytes = max(1_024, maxBytes)
            }
        }
        if let settings = document.foundationObject(forKey: "settings"),
           let path = settings["skillsFolderPath"] as? String {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            config.skillsFolderPath = trimmed.isEmpty ? nil : trimmed
        }
        if let sections = document.foundationObject(forKey: "lineagePromptSections"),
           let template = sections["subAgent"] as? String {
            let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                config.subAgentContextTemplate = template
            }
        }
        return config
    }
}

/// Compact Codable snapshot of assembly-relevant PromptConfig values embedded in replay records.
public struct PromptAssemblyConfigSnapshot: Sendable, Equatable, Codable {
    public var includeCurrentDateTime: Bool
    public var includeAgentSkills: Bool
    public var strictAgentHarnessPrompts: Bool
    public var skillsFolderPath: String?
    public var subAgentContextTemplate: String
    public var assemblyCheckpointMode: SystemPromptAssemblyCheckpointMode
    public var assemblyCheckpointMaxFullTextBytes: Int

    public init(from configuration: HarnessConfigurationSet) {
        let assembly = configuration.promptAssembly
        self.includeCurrentDateTime = assembly.includeCurrentDateTime
        self.includeAgentSkills = assembly.includeAgentSkills
        self.strictAgentHarnessPrompts = configuration.agentHarness.strictAgentHarnessPrompts
        self.skillsFolderPath = assembly.skillsFolderPath
        self.subAgentContextTemplate = assembly.subAgentContextTemplate
        self.assemblyCheckpointMode = assembly.assemblyCheckpointMode
        self.assemblyCheckpointMaxFullTextBytes = assembly.assemblyCheckpointMaxFullTextBytes
    }

    public init(from assembly: PromptAssemblyConfiguration, strictAgentHarnessPrompts: Bool) {
        self.includeCurrentDateTime = assembly.includeCurrentDateTime
        self.includeAgentSkills = assembly.includeAgentSkills
        self.strictAgentHarnessPrompts = strictAgentHarnessPrompts
        self.skillsFolderPath = assembly.skillsFolderPath
        self.subAgentContextTemplate = assembly.subAgentContextTemplate
        self.assemblyCheckpointMode = assembly.assemblyCheckpointMode
        self.assemblyCheckpointMaxFullTextBytes = assembly.assemblyCheckpointMaxFullTextBytes
    }

    public var asPromptAssemblyConfiguration: PromptAssemblyConfiguration {
        PromptAssemblyConfiguration(
            includeCurrentDateTime: includeCurrentDateTime,
            includeAgentSkills: includeAgentSkills,
            skillsFolderPath: skillsFolderPath,
            subAgentContextTemplate: subAgentContextTemplate,
            assemblyCheckpointMode: assemblyCheckpointMode,
            assemblyCheckpointMaxFullTextBytes: assemblyCheckpointMaxFullTextBytes
        )
    }
}
