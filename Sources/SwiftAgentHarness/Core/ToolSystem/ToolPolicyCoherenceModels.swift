import Foundation

enum ToolPolicyCoherenceIssueKind: String, Sendable, Equatable {
    case unknownEntry
    case shadowedAllow
    case emptyGroup
    case grantSuppressedByEmptyAllow
}

enum ToolPolicyCoherenceScope: String, Sendable, Equatable {
    case modeToolsAllow
    case modeToolsDeny
    case routingToolsAllow
    case routingToolsDeny
    case promptConfigSensitive
    case promptConfigRequireApproval
    case promptConfigEscalationRequired
    case promptConfigElevated
    case hostVisibilityGrant

    var displayLabel: String {
        switch self {
        case .modeToolsAllow: return "Mode tools.allow"
        case .modeToolsDeny: return "Mode tools.deny"
        case .routingToolsAllow: return "Routing tools allowlist"
        case .routingToolsDeny: return "Routing tools denylist"
        case .promptConfigSensitive: return "PromptConfig.toolPolicy.sensitive"
        case .promptConfigRequireApproval: return "PromptConfig.toolPolicy.requireApproval"
        case .promptConfigEscalationRequired: return "PromptConfig.toolPolicy.escalationRequired"
        case .promptConfigElevated: return "PromptConfig.toolPolicy.elevated"
        case .hostVisibilityGrant: return "Host visibility grant"
        }
    }

    func fixItConfigKey(profileID: String) -> String {
        switch self {
        case .modeToolsAllow:
            return "modeProfiles.\(profileID).tools.allow"
        case .modeToolsDeny:
            return "modeProfiles.\(profileID).tools.deny"
        case .routingToolsAllow, .routingToolsDeny:
            return "conversation.routingPrefs.explicitToolPolicy"
        case .promptConfigSensitive:
            return "PromptConfig.toolPolicy.sensitive"
        case .promptConfigRequireApproval:
            return "PromptConfig.toolPolicy.requireApproval"
        case .promptConfigEscalationRequired:
            return "PromptConfig.toolPolicy.escalationRequired"
        case .promptConfigElevated:
            return "PromptConfig.toolPolicy.elevated"
        case .hostVisibilityGrant:
            return "modeProfiles.\(profileID).allowsHostGrants / modeProfiles.\(profileID).tools.allow"
        }
    }
}

struct ToolPolicyCoherencePolicyList: Sendable, Equatable {
    let scope: ToolPolicyCoherenceScope
    let rules: [ToolPolicyRule]
}

struct ToolPolicyCoherenceIssue: Sendable, Equatable, Hashable {
    let kind: ToolPolicyCoherenceIssueKind
    let scope: ToolPolicyCoherenceScope
    let ruleToken: String
    let detail: String
    let shadowedBy: [String]

    var dedupeKey: String {
        let shadowKey = shadowedBy.sorted().joined(separator: "|")
        return "\(kind.rawValue)|\(scope.rawValue)|\(ruleToken)|\(shadowKey)"
    }

    func fixItConfigKey(profileID: String) -> String {
        scope.fixItConfigKey(profileID: profileID)
    }
}

struct ToolPolicyCoherenceReport: Sendable {
    let profileID: String
    let issues: [ToolPolicyCoherenceIssue]

    var unknownEntries: [ToolPolicyCoherenceIssue] {
        issues.filter { $0.kind == .unknownEntry }
    }

    var shadowedAllows: [ToolPolicyCoherenceIssue] {
        issues.filter { $0.kind == .shadowedAllow }
    }

    var emptyGroups: [ToolPolicyCoherenceIssue] {
        issues.filter { $0.kind == .emptyGroup }
    }

    var grantSuppressedByEmptyAllow: [ToolPolicyCoherenceIssue] {
        issues.filter { $0.kind == .grantSuppressedByEmptyAllow }
    }

    var isClean: Bool {
        issues.isEmpty
    }
}

