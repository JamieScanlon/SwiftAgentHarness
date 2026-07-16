import Foundation

/// Policy scope identifiers aligned with the availability pipeline in ``DefaultToolSystemGateway``.
enum ToolPolicyAvailabilityScope: String, Sendable, CaseIterable, Equatable {
    case inputTrust
    case turnEnableTools
    case executionEnvironment
    case subAgentRecursion
    case enableAgents
    case subAgentHosting
    case modeDeny
    case escalation
    case approval
    case modeAllow
    case hostVisibilityGrant
    case routingToolPolicy

    var displayLabel: String {
        switch self {
        case .inputTrust: return "Input trust"
        case .turnEnableTools: return "Turn enableTools"
        case .executionEnvironment: return "Execution environment"
        case .subAgentRecursion: return "Sub-agent recursion depth"
        case .enableAgents: return "Turn enableAgents"
        case .subAgentHosting: return "Sub-agent hosting policy"
        case .modeDeny: return "Mode tools.deny"
        case .escalation: return "Escalation required"
        case .approval: return "Approval / elevated gate"
        case .modeAllow: return "Mode tools.allow"
        case .hostVisibilityGrant: return "Host visibility grant"
        case .routingToolPolicy: return "Conversation routing tool policy"
        }
    }

    func fixItConfigKey(profileID: String) -> String {
        switch self {
        case .inputTrust:
            return "trustPolicy / turn inputTrustRaw"
        case .turnEnableTools:
            return "turn configuration enableTools"
        case .executionEnvironment:
            return "PromptConfig.toolPolicy.executionEnvironment.*"
        case .subAgentRecursion:
            return "sub-agent maxRecursionDepth"
        case .enableAgents:
            return "turn configuration enableAgents"
        case .subAgentHosting:
            return "PromptConfig.toolPolicy.subAgentHosting.*"
        case .modeDeny:
            return "modeProfiles.\(profileID).tools.deny"
        case .escalation:
            return "PromptConfig.toolPolicy.escalationRequired or turn allowEscalatedTools"
        case .approval:
            return "PromptConfig.toolPolicy.requireApproval, approve tool, or durable grant"
        case .modeAllow:
            return "modeProfiles.\(profileID).tools.allow"
        case .hostVisibilityGrant:
            return "setMCPManager(visibilityGrant:) / installAdditionalToolProviders(visibilityGrant:) or modeProfiles.\(profileID).allowsHostGrants / tools.allow"
        case .routingToolPolicy:
            return "conversation.routingPrefs.explicitToolPolicy"
        }
    }

    init?(blockReason: ToolAvailabilityBlockReason) {
        switch blockReason {
        case .toolsDisabledForSend:
            return nil
        case .agentsDisabledForRemoteAgentTool:
            self = .enableAgents
        case .promptConfigAllowlist:
            self = .modeAllow
        case .promptConfigDenylist:
            self = .modeDeny
        case .escalationRequired:
            self = .escalation
        case .approvalRequired:
            self = .approval
        case .executionEnvironmentPolicyDenied:
            self = .executionEnvironment
        case .recursionDepthExceeded:
            self = .subAgentRecursion
        case .hostingRoutingPolicyDenied:
            self = .subAgentHosting
        case .routingToolWhitelist:
            self = .routingToolPolicy
        case .hostVisibilityGrantMiss:
            self = .hostVisibilityGrant
        }
    }
}

enum ToolPolicyScopeVerdict: Sendable, Equatable {
    case pass
    case fail(scope: ToolPolicyAvailabilityScope, detail: String, matchedRule: String?)
    case gate(scope: ToolPolicyAvailabilityScope, detail: String)

    var scope: ToolPolicyAvailabilityScope? {
        switch self {
        case .pass:
            return nil
        case .fail(let scope, _, _), .gate(let scope, _):
            return scope
        }
    }
}

enum ToolPolicyToolExplainStatus: Sendable, Equatable {
    case effective
    case approvalGated
    case blocked
}

struct ToolPolicyExplainContext: Sendable, Equatable {
    let profileID: String
    let interactionMode: InteractionMode
    let enableTools: Bool
    let enableAgents: Bool
    let allowEscalatedTools: Bool
    let inputTrustClass: TrustPolicyClass?
}

struct ToolPolicyGatingExplainAppendix: Sendable {
    let behavior: ToolPolicyDecisionBehavior
    let reasonDescription: String
}

struct ToolPolicyToolExplainRow: Sendable {
    let toolName: String
    let source: ToolListingSource
    let status: ToolPolicyToolExplainStatus
    let primaryScope: ToolPolicyAvailabilityScope?
    let primaryDetail: String?
    let fixItConfigKey: String?
    let scopeTrace: [(scope: ToolPolicyAvailabilityScope, verdict: ToolPolicyScopeVerdict)]
    let gatewayBlockReason: ToolAvailabilityBlockReason?
    let gatingAppendix: ToolPolicyGatingExplainAppendix?
}

struct ToolPolicyExplainReport: Sendable {
    let context: ToolPolicyExplainContext
    let registeredToolCount: Int
    let rows: [ToolPolicyToolExplainRow]

    var effectiveCount: Int {
        rows.filter { $0.status == .effective }.count
    }

    var approvalGatedCount: Int {
        rows.filter { $0.status == .approvalGated }.count
    }

    var blockedCount: Int {
        rows.filter { $0.status == .blocked }.count
    }
}
