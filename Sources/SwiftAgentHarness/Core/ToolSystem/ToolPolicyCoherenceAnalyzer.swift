import Foundation

enum ToolPolicyCoherenceAnalyzer {
    private static let staticCoreGroups: Set<String> = ["fs", "runtime", "web"]
    private static let builtInDynamicGroups: Set<String> = ["mcp", "a2a", "plugins"]

    static func analyze(
        entries: [ToolRegistryEntry],
        modePolicyContext: ModePolicyContext,
        toolPolicy: ToolPolicyConfiguration,
        conversation: ModelConversation?
    ) -> ToolPolicyCoherenceReport {
        let groupIndex = ToolPolicyGroupIndex.build(from: entries)
        let registryNames = Set(entries.map { ToolNamePolicyNormalization.registryName($0) })
        let profileID = modePolicyContext.resolvedProfile.id
        var issues: [ToolPolicyCoherenceIssue] = []

        let modeAllow = modePolicyContext.resolvedProfile.tools.allow
        let modeDeny = modePolicyContext.resolvedProfile.tools.deny
        let modeAllowRules = ToolPolicyRulesCache.parseOptionalList(modeAllow) ?? []
        let modeDenyRules = ToolPolicyRulesCache.parseList(modeDeny)

        issues.append(contentsOf: unknownIssues(
            rules: modeAllowRules,
            scope: .modeToolsAllow,
            entries: entries,
            registryNames: registryNames,
            groupIndex: groupIndex,
            skipWildcard: true
        ))
        issues.append(contentsOf: unknownIssues(
            rules: modeDenyRules,
            scope: .modeToolsDeny,
            entries: entries,
            registryNames: registryNames,
            groupIndex: groupIndex,
            skipWildcard: false
        ))
        issues.append(contentsOf: shadowedAllowIssues(
            allowRules: modeAllowRules,
            denyRules: modeDenyRules,
            allowScope: .modeToolsAllow,
            entries: entries,
            groupIndex: groupIndex
        ))

        if let routingPrefs = conversation?.routingPrefs,
           let explicitPolicy = routingPrefs.explicitToolPolicy {
            switch explicitPolicy {
            case .allowlist(let tools, _):
                let allowRules = ToolPolicyRulesCache.parseList(tools)
                issues.append(contentsOf: unknownIssues(
                    rules: allowRules,
                    scope: .routingToolsAllow,
                    entries: entries,
                    registryNames: registryNames,
                    groupIndex: groupIndex,
                    skipWildcard: true
                ))
            case .denylist(let tools, _):
                let denyRules = ToolPolicyRulesCache.parseList(tools)
                issues.append(contentsOf: unknownIssues(
                    rules: denyRules,
                    scope: .routingToolsDeny,
                    entries: entries,
                    registryNames: registryNames,
                    groupIndex: groupIndex,
                    skipWildcard: false
                ))
            }
        }

        for list in toolPolicy.coherencePolicyLists() {
            issues.append(contentsOf: unknownIssues(
                rules: list.rules,
                scope: list.scope,
                entries: entries,
                registryNames: registryNames,
                groupIndex: groupIndex,
                skipWildcard: false
            ))
        }

        return ToolPolicyCoherenceReport(
            profileID: profileID,
            issues: deduplicatedIssues(issues)
        )
    }

    static func catalogFingerprint(from entries: [ToolRegistryEntry]) -> String {
        entries.map(\.name).sorted().joined(separator: "|")
    }

    private static func deduplicatedIssues(_ issues: [ToolPolicyCoherenceIssue]) -> [ToolPolicyCoherenceIssue] {
        var seen: Set<String> = []
        var result: [ToolPolicyCoherenceIssue] = []
        for issue in issues {
            guard seen.insert(issue.dedupeKey).inserted else { continue }
            result.append(issue)
        }
        return result
    }

    private static func unknownIssues(
        rules: [ToolPolicyRule],
        scope: ToolPolicyCoherenceScope,
        entries: [ToolRegistryEntry],
        registryNames: Set<String>,
        groupIndex: ToolPolicyGroupIndex,
        skipWildcard: Bool
    ) -> [ToolPolicyCoherenceIssue] {
        rules.compactMap { rule in
            classifyUnknownRule(
                rule: rule,
                scope: scope,
                entries: entries,
                registryNames: registryNames,
                groupIndex: groupIndex,
                skipWildcard: skipWildcard
            )
        }
    }

    private static func classifyUnknownRule(
        rule: ToolPolicyRule,
        scope: ToolPolicyCoherenceScope,
        entries: [ToolRegistryEntry],
        registryNames: Set<String>,
        groupIndex: ToolPolicyGroupIndex,
        skipWildcard: Bool
    ) -> ToolPolicyCoherenceIssue? {
        switch rule {
        case .argumentMatcher:
            return nil
        case .wildcard:
            return skipWildcard ? nil : nil
        case .bareName(let name):
            guard !registryNames.contains(name) else { return nil }
            return ToolPolicyCoherenceIssue(
                kind: .unknownEntry,
                scope: scope,
                ruleToken: rule.rawToken,
                detail: "Rule '\(rule.rawToken)' matches no registered tool in the current catalog.",
                shadowedBy: []
            )
        case .nameGlob, .groupAlias:
            let matched = entriesMatching(rule: rule, entries: entries, groupIndex: groupIndex)
            guard matched.isEmpty else { return nil }
            if case .groupAlias(let groupID) = rule {
                if staticCoreGroups.contains(groupID.lowercased()) {
                    return nil
                }
                if !builtInDynamicGroups.contains(groupID.lowercased()) {
                    return ToolPolicyCoherenceIssue(
                        kind: .emptyGroup,
                        scope: scope,
                        ruleToken: rule.rawToken,
                        detail: "Custom group '\(rule.rawToken)' has no members in the current catalog.",
                        shadowedBy: []
                    )
                }
            }
            return ToolPolicyCoherenceIssue(
                kind: .unknownEntry,
                scope: scope,
                ruleToken: rule.rawToken,
                detail: "Rule '\(rule.rawToken)' matches no registered tool in the current catalog.",
                shadowedBy: []
            )
        }
    }

    private static func shadowedAllowIssues(
        allowRules: [ToolPolicyRule],
        denyRules: [ToolPolicyRule],
        allowScope: ToolPolicyCoherenceScope,
        entries: [ToolRegistryEntry],
        groupIndex: ToolPolicyGroupIndex
    ) -> [ToolPolicyCoherenceIssue] {
        guard !allowRules.isEmpty, !denyRules.isEmpty else { return [] }
        let nameLevelAllowRules = allowRules.filter(\.isNameLevelRule)
        let nameLevelDenyRules = denyRules.filter(\.isNameLevelRule)
        guard !nameLevelDenyRules.isEmpty else { return [] }

        return nameLevelAllowRules.compactMap { allowRule in
            let matchedEntries = entriesMatching(rule: allowRule, entries: entries, groupIndex: groupIndex)
            guard !matchedEntries.isEmpty else { return nil }

            var shadowingDenyTokens: [String] = []
            for entry in matchedEntries {
                let registryName = ToolNamePolicyNormalization.registryName(entry)
                let blockingDenies = nameLevelDenyRules.filter { denyRule in
                    ToolPolicyNameMatcher.matches(
                        rule: denyRule,
                        toolName: registryName,
                        entry: entry,
                        groupIndex: groupIndex
                    )
                }
                guard !blockingDenies.isEmpty else { return nil }
                for denyRule in blockingDenies {
                    let token = denyRule.rawToken
                    if !shadowingDenyTokens.contains(token) {
                        shadowingDenyTokens.append(token)
                    }
                }
            }

            return ToolPolicyCoherenceIssue(
                kind: .shadowedAllow,
                scope: allowScope,
                ruleToken: allowRule.rawToken,
                detail: "Allow rule '\(allowRule.rawToken)' is unreachable because deny-wins shadowing covers every matched tool.",
                shadowedBy: shadowingDenyTokens.sorted()
            )
        }
    }

    private static func entriesMatching(
        rule: ToolPolicyRule,
        entries: [ToolRegistryEntry],
        groupIndex: ToolPolicyGroupIndex
    ) -> [ToolRegistryEntry] {
        entries.filter { entry in
            ToolPolicyNameMatcher.matches(
                rule: rule,
                toolName: ToolNamePolicyNormalization.registryName(entry),
                entry: entry,
                groupIndex: groupIndex
            )
        }
    }
}
