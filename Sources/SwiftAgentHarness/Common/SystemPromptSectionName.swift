import Foundation

/// Canonical named sections for system-prompt assembly (harness-template layout).
public enum SystemPromptSectionName: String, Sendable, CaseIterable, Hashable, Codable {
    case identity
    case capabilities
    case constraints
    case personality
    case modeDirective
    case memory
    case skills
    case toolGuidance
    case attachments
    case extraInstructions
    case dynamicAdditions

    public var isVolatile: Bool {
        switch self {
        case .identity, .capabilities, .constraints, .personality, .modeDirective, .memory:
            return false
        case .skills, .toolGuidance, .attachments, .extraInstructions, .dynamicAdditions:
            return true
        }
    }

    public var displayTitle: String {
        switch self {
        case .identity: return "Conversation"
        case .capabilities: return "Capabilities"
        case .constraints: return "Constraints"
        case .personality: return "Personality"
        case .modeDirective: return "Mode Directive"
        case .memory: return "Memory"
        case .skills: return "Agent Skills"
        case .toolGuidance: return "Tools"
        case .attachments: return "Attachments"
        case .extraInstructions: return "Additional Requirements"
        case .dynamicAdditions: return "Dynamic Additions"
        }
    }

    /// Sections that file- or conversation-sourced layers must not suppress.
    public static let nonSuppressible: Set<SystemPromptSectionName> = [.constraints]

    /// Maps legacy mode-profile / provider suppress and override keys to canonical section names.
    public static func canonicalSection(forLegacyKey raw: String) -> SystemPromptSectionName? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "conversation", "identity":
            return .identity
        case "capabilities":
            return .capabilities
        case "constraints":
            return .constraints
        case "personality":
            return .personality
        case "mode_directive", "modedirective", "plan", "agent", "workflow":
            return .modeDirective
        case "memory":
            return .memory
        case "skills":
            return .skills
        case "tools", "tool_guidance", "toolguidance":
            return .toolGuidance
        case "attachments":
            return .attachments
        case "additional_requirements", "additionalrequirements", "extra_instructions":
            return .extraInstructions
        case "sub_agent_context", "subagentcontext", "sub_agent", "triggers", "dynamic_additions":
            return .dynamicAdditions
        case "interaction_style", "interactionstyle":
            return .dynamicAdditions
        case "tool_call_style", "toolcallstyle":
            return .toolGuidance
        case "execution_bias", "executionbias":
            return .dynamicAdditions
        default:
            return nil
        }
    }

    public static let stableAssemblyOrder: [SystemPromptSectionName] = [
        .identity, .capabilities, .constraints, .personality, .modeDirective, .memory,
    ]

    public static let volatileAssemblyOrder: [SystemPromptSectionName] = [
        .skills, .toolGuidance, .attachments, .extraInstructions, .dynamicAdditions,
    ]

    public var dynamicPromptToken: String {
        "section\(rawValue.prefix(1).uppercased())\(rawValue.dropFirst())"
    }
}
