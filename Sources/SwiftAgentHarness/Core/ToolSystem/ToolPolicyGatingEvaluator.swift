import EasyJSON
import Foundation

enum ToolPolicyDecisionBehavior: Sendable, Equatable {
    case allow
    case ask
    case deny
}

enum ToolPolicyDecisionReasonKind: Sendable, Equatable {
    case rule
    case mode
    case durableGrant
    case binding
    case composition
}

struct ToolPolicyDecisionReason: Sendable, Equatable {
    let kind: ToolPolicyDecisionReasonKind
    let rule: ToolPolicyRule?
    let scope: String?

    static func rule(_ rule: ToolPolicyRule, scope: String) -> Self {
        Self(kind: .rule, rule: rule, scope: scope)
    }

    static func durableGrant(_ rule: ToolPolicyRule) -> Self {
        Self(kind: .durableGrant, rule: rule, scope: nil)
    }

    static func binding(scope: String) -> Self {
        Self(kind: .binding, rule: nil, scope: scope)
    }
}

struct ToolPolicyGatingDecision: Sendable, Equatable {
    let behavior: ToolPolicyDecisionBehavior
    let reason: ToolPolicyDecisionReason?

    static let allow = ToolPolicyGatingDecision(behavior: .allow, reason: nil)
    static let askDefault = ToolPolicyGatingDecision(behavior: .ask, reason: nil)
    static let denyDefault = ToolPolicyGatingDecision(behavior: .deny, reason: nil)

    static func allow(reason: ToolPolicyDecisionReason) -> Self {
        Self(behavior: .allow, reason: reason)
    }

    static func deny(reason: ToolPolicyDecisionReason) -> Self {
        Self(behavior: .deny, reason: reason)
    }
}

struct ToolPolicyGatingScope: Sendable, Equatable {
    let name: String
    let allowRules: [ToolPolicyRule]?
    let denyRules: [ToolPolicyRule]
    let autoAllowRules: [ToolPolicyRule]

    init(
        name: String,
        allowRules: [ToolPolicyRule]? = nil,
        denyRules: [ToolPolicyRule] = [],
        autoAllowRules: [ToolPolicyRule] = []
    ) {
        self.name = name
        self.allowRules = allowRules
        self.denyRules = denyRules
        self.autoAllowRules = autoAllowRules
    }
}

enum ToolPolicyGatingEvaluator {
    static func evaluate(
        entry: ToolRegistryEntry,
        arguments: JSON,
        groupIndex: ToolPolicyGroupIndex,
        scopes: [ToolPolicyGatingScope],
        bindingPreApproved: Bool = false
    ) -> ToolPolicyGatingDecision {
        if bindingPreApproved {
            return .allow(reason: .binding(scope: "allow-once"))
        }

        for scope in scopes {
            let denyRules = parsedRules(scope.denyRules)
            if ToolPolicyCallMatcher.listMatches(
                rules: denyRules,
                entry: entry,
                arguments: arguments,
                groupIndex: groupIndex
            ) {
                if let matched = denyRules.first(where: {
                    ToolPolicyCallMatcher.matches(rule: $0, entry: entry, arguments: arguments, groupIndex: groupIndex)
                }) {
                    return .deny(reason: .rule(matched, scope: scope.name))
                }
                return .denyDefault
            }
        }

        for scope in scopes {
            let autoAllow = parsedRules(scope.autoAllowRules)
            if ToolPolicyCallMatcher.listMatches(
                rules: autoAllow,
                entry: entry,
                arguments: arguments,
                groupIndex: groupIndex
            ) {
                if let matched = autoAllow.first(where: {
                    ToolPolicyCallMatcher.matches(rule: $0, entry: entry, arguments: arguments, groupIndex: groupIndex)
                }) {
                    return .allow(reason: .durableGrant(matched))
                }
                return .allow
            }
        }

        for scope in scopes {
            if let allowRules = scope.allowRules {
                let parsed = parsedRules(allowRules)
                if !parsed.isEmpty,
                   !ToolPolicyCallMatcher.listMatches(
                       rules: parsed,
                       entry: entry,
                       arguments: arguments,
                       groupIndex: groupIndex
                   ) {
                    return .denyDefault
                }
            }
        }

        return .askDefault
    }

    private static func parsedRules(_ rules: [ToolPolicyRule]) -> [ToolPolicyRule] {
        rules
    }
}

enum ToolPolicyRulesCache {
    static func parseList(_ tokens: [String]) -> [ToolPolicyRule] {
        (try? ToolPolicyRuleParser.parseMany(tokens)) ?? tokens.map {
            .bareName(ToolNamePolicyNormalization.canonical($0))
        }
    }

    static func parseOptionalList(_ tokens: [String]?) -> [ToolPolicyRule]? {
        guard let tokens else { return nil }
        return parseList(tokens)
    }

    static func preserveTokenForStorage(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return "*" }
        if trimmed.lowercased().hasPrefix("group:") { return trimmed.lowercased() }
        if trimmed.contains("(") || trimmed.contains("*") || trimmed.contains("?") {
            return trimmed
        }
        return ToolNamePolicyNormalization.canonical(trimmed)
    }
}
