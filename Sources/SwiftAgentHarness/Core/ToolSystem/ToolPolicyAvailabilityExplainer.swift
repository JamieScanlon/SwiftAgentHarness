import EasyJSON
import Foundation
import SwiftAgentKit

enum ToolPolicyAvailabilityExplainer {
    static func explain(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        gateway: any ToolSystemGatewaying,
        filterToolName: String? = nil,
        gatingArgumentPreview: String? = nil
    ) -> ToolPolicyExplainReport {
        let groupIndex = ToolPolicyGroupIndex.build(from: entries)
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: configuration.inputTrustRaw,
                unknownFallback: trustPolicy.safeDefaultClass
            )
        let context = ToolPolicyExplainContext(
            profileID: modePolicyContext.resolvedProfile.id,
            interactionMode: modePolicyContext.interactionMode,
            enableTools: configuration.enableTools,
            enableAgents: configuration.enableAgents,
            allowEscalatedTools: configuration.allowEscalatedTools,
            inputTrustClass: trustClass
        )

        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let filteredEntries: [ToolRegistryEntry]
        if let filterToolName, !filterToolName.isEmpty {
            filteredEntries = sortedEntries.filter {
                ToolNamePolicyNormalization.matchesRegistryName(callName: filterToolName, entryName: $0.name)
            }
        } else {
            filteredEntries = sortedEntries
        }

        let rows = filteredEntries.map { entry in
            explainEntry(
                entry: entry,
                conversation: conversation,
                modePolicyContext: modePolicyContext,
                configuration: configuration,
                toolPolicy: toolPolicy,
                trustPolicy: trustPolicy,
                subAgentToolClassifier: subAgentToolClassifier,
                groupIndex: groupIndex,
                trustClass: trustClass,
                context: context,
                gateway: gateway,
                gatingArgumentPreview: filterToolName != nil ? gatingArgumentPreview : nil
            )
        }

        return ToolPolicyExplainReport(
            context: context,
            registeredToolCount: entries.count,
            rows: rows
        )
    }

    private static func explainEntry(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        groupIndex: ToolPolicyGroupIndex,
        trustClass: TrustPolicyClass,
        context: ToolPolicyExplainContext,
        gateway: any ToolSystemGatewaying,
        gatingArgumentPreview: String?
    ) -> ToolPolicyToolExplainRow {
        let executionEnvironmentKind = ToolPolicyConfiguration.ExecutionEnvironmentKind(
            rawValue: entry.executionEnvironment.kind.rawValue
        ) ?? .unknown
        let executionEnvironmentAdapterID = entry.executionEnvironment.adapterID

        var trace: [(scope: ToolPolicyAvailabilityScope, verdict: ToolPolicyScopeVerdict)] = []

        func record(_ scope: ToolPolicyAvailabilityScope, _ verdict: ToolPolicyScopeVerdict) {
            trace.append((scope, verdict))
        }

        if trustPolicy.shouldGateExecution(for: trustClass) {
            record(.inputTrust, .fail(
                scope: .inputTrust,
                detail: "Input trust class `\(trustClass.rawValue)` gates tool execution.",
                matchedRule: nil
            ))
        } else {
            record(.inputTrust, .pass)
        }

        if !configuration.enableTools {
            record(.turnEnableTools, .fail(
                scope: .turnEnableTools,
                detail: "Tools are disabled for this turn (`enableTools=false`).",
                matchedRule: nil
            ))
        } else {
            record(.turnEnableTools, .pass)
        }

        let envAllowed = toolPolicy.isExecutionEnvironmentAllowed(kind: executionEnvironmentKind)
            && toolPolicy.isExecutionEnvironmentAdapterAllowed(adapterID: executionEnvironmentAdapterID)
        if !envAllowed {
            record(.executionEnvironment, .fail(
                scope: .executionEnvironment,
                detail: "Environment kind `\(executionEnvironmentKind.rawValue)` or adapter `\(executionEnvironmentAdapterID)` is disallowed.",
                matchedRule: nil
            ))
        } else {
            record(.executionEnvironment, .pass)
        }

        let isDelegateTool = subAgentToolClassifier?.isDelegateTool(entry: entry) ?? (entry.source == .a2a)

        if isDelegateTool,
           let maxRecursionDepth = subAgentToolClassifier?.maxRecursionDepth(for: entry),
           delegateDepth(for: conversation) >= maxRecursionDepth {
            record(.subAgentRecursion, .fail(
                scope: .subAgentRecursion,
                detail: "Delegate depth \(delegateDepth(for: conversation)) reached limit \(maxRecursionDepth).",
                matchedRule: nil
            ))
        } else {
            record(.subAgentRecursion, .pass)
        }

        if !configuration.enableAgents, isDelegateTool {
            record(.enableAgents, .fail(
                scope: .enableAgents,
                detail: "Remote agent tools require `enableAgents=true`.",
                matchedRule: nil
            ))
        } else {
            record(.enableAgents, .pass)
        }

        if isDelegateTool,
           !hostingRoutingPermits(
                toolName: entry.name,
                conversation: conversation,
                toolPolicy: toolPolicy,
                modePolicyContext: modePolicyContext,
                groupIndex: groupIndex
           ) {
            record(.subAgentHosting, .fail(
                scope: .subAgentHosting,
                detail: "Sub-agent hosting / routing isolation rejected delegate tool.",
                matchedRule: nil
            ))
        } else {
            record(.subAgentHosting, .pass)
        }

        let modeDenyRules = ToolPolicyRulesCache.parseList(modePolicyContext.resolvedProfile.tools.deny)
        if ToolPolicyNameMatcher.denylistBlocks(
            rules: modeDenyRules,
            toolName: entry.name,
            entry: entry,
            groupIndex: groupIndex
        ) {
            let matched = firstMatchingNameRule(
                rules: modeDenyRules,
                entry: entry,
                groupIndex: groupIndex
            )
            record(.modeDeny, .fail(
                scope: .modeDeny,
                detail: "Matched mode deny rule.",
                matchedRule: matched
            ))
        } else {
            record(.modeDeny, .pass)
        }

        let escalationRequired = toolPolicy.requiresEscalation(name: entry.name, groupIndex: groupIndex)
            || toolPolicy.requiresExecutionEnvironmentEscalation(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterEscalation(adapterID: executionEnvironmentAdapterID)
        if escalationRequired, !configuration.allowEscalatedTools {
            record(.escalation, .fail(
                scope: .escalation,
                detail: "Tool requires escalation and turn `allowEscalatedTools` is false.",
                matchedRule: nil
            ))
        } else {
            record(.escalation, .pass)
        }

        let toolIsReadOnly = ToolCallCapabilityClassifier.isPolymorphic(entry.name)
            ? true
            : (entry.effectClass == .readOnly)
        let requiresApproval = toolPolicy.requiresApproval(
            toolName: entry.name,
            context: modePolicyContext,
            toolIsReadOnly: toolIsReadOnly,
            entryRequiresApprovalTag: entry.policyTags.contains(.requiresApproval)
        ) || toolPolicy.requiresExecutionEnvironmentApproval(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterApproval(adapterID: executionEnvironmentAdapterID)
        let isElevated = (toolPolicy.isElevatedTool(name: entry.name, groupIndex: groupIndex)
            || entry.policyTags.contains(.elevated))
            && !toolPolicy.isPerCallElevatedTool(name: entry.name, groupIndex: groupIndex)
        let delegatePermissionPolicy = isDelegateTool
            ? (subAgentToolClassifier?.permissionPolicy(for: entry) ?? .askUser)
            : nil
        let approvalRequiredByDelegationRoute = isDelegateTool && delegatePermissionPolicy != .auto
        let approvalRequiredFinal = requiresApproval || isElevated || approvalRequiredByDelegationRoute
        let approvalGranted = ToolNamePolicyNormalization.setContains(
            configuration.preApprovedToolNames,
            name: entry.name
        )
        if approvalRequiredFinal, !approvalGranted {
            record(.approval, .gate(
                scope: .approval,
                detail: isElevated
                    ? "Elevated tool requires explicit approval."
                    : "Tool requires explicit approval before dispatch."
            ))
        } else {
            record(.approval, .pass)
        }

        if !toolPolicy.isToolAllowed(
            name: entry.name,
            context: modePolicyContext,
            groupIndex: groupIndex,
            entry: entry
        ) {
            let grants = (gateway as? DefaultToolSystemGateway)?.visibilityGrants.snapshot()
                ?? ToolVisibilityGrantTable.empty
            let profile = modePolicyContext.resolvedProfile
            let effectiveAllow = grants.effectiveAllowList(
                authored: profile.tools.allow,
                entry: entry,
                profile: profile
            )
            let effectiveSlice = ModeProfileToolsSlice(
                allow: effectiveAllow,
                deny: profile.tools.deny,
                approvalPolicy: profile.tools.approvalPolicy
            )
            var effectiveProfile = profile
            effectiveProfile.tools = effectiveSlice
            let effectiveContext = ModePolicyContext(
                interactionMode: modePolicyContext.interactionMode,
                resolvedProfile: effectiveProfile
            )
            if toolPolicy.isToolAllowed(
                name: entry.name,
                context: effectiveContext,
                groupIndex: groupIndex,
                entry: entry
            ) {
                record(.modeAllow, .pass)
            } else {
                let allowList = effectiveAllow ?? []
                record(.modeAllow, .fail(
                    scope: .modeAllow,
                    detail: allowList.isEmpty
                        ? "Closed-world mode allow list is empty."
                        : "Not matched by mode allow list.",
                    matchedRule: allowList.isEmpty ? nil : allowList.joined(separator: ", ")
                ))
            }
        } else {
            record(.modeAllow, .pass)
        }

        if !routingToolPolicyPermits(
            toolName: entry.name,
            conversation: conversation,
            groupIndex: groupIndex,
            entry: entry
        ) {
            let routingSummary = routingPolicySummary(conversation: conversation)
            record(.routingToolPolicy, .fail(
                scope: .routingToolPolicy,
                detail: routingSummary ?? "Blocked by conversation routing tool policy.",
                matchedRule: routingSummary
            ))
        } else {
            record(.routingToolPolicy, .pass)
        }

        let gatewayDecision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: modePolicyContext,
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentToolClassifier,
            groupIndex: groupIndex
        )

        let status: ToolPolicyToolExplainStatus
        if gatewayDecision.allowed {
            status = .effective
        } else if gatewayDecision.blockReason == .approvalRequired {
            status = .approvalGated
        } else {
            status = .blocked
        }

        let primaryScope: ToolPolicyAvailabilityScope?
        let primaryDetail: String?
        if gatewayDecision.blockReason == .toolsDisabledForSend {
            if trustPolicy.shouldGateExecution(for: trustClass) {
                primaryScope = .inputTrust
                primaryDetail = trace.first { $0.scope == .inputTrust }
                    .map { ToolPolicyScopeVerdictFormatting.detailText(for: $0.verdict) } ?? nil
            } else {
                primaryScope = .turnEnableTools
                primaryDetail = trace.first { $0.scope == .turnEnableTools }
                    .map { ToolPolicyScopeVerdictFormatting.detailText(for: $0.verdict) } ?? nil
            }
        } else if let mapped = gatewayDecision.blockReason.flatMap(ToolPolicyAvailabilityScope.init(blockReason:)) {
            primaryScope = mapped
            primaryDetail = trace.first { $0.scope == mapped }
                .map { ToolPolicyScopeVerdictFormatting.detailText(for: $0.verdict) } ?? nil
        } else {
            primaryScope = trace.first {
                switch $0.verdict {
                case .fail, .gate:
                    return true
                case .pass:
                    return false
                }
            }?.scope
            primaryDetail = trace.first {
                switch $0.verdict {
                case .fail, .gate:
                    return true
                case .pass:
                    return false
                }
            }.map { ToolPolicyScopeVerdictFormatting.detailText(for: $0.verdict) } ?? nil
        }

        let fixIt: String?
        fixIt = primaryScope.map { $0.fixItConfigKey(profileID: context.profileID) }

        let resolvedPrimaryDetail: String? = primaryDetail

        var gatingAppendix: ToolPolicyGatingExplainAppendix?
        if let gatingArgumentPreview {
            let arguments = argumentPreviewJSON(toolName: entry.name, preview: gatingArgumentPreview)
            let call = ToolCallRequest(id: "explain-preview", name: entry.name, arguments: arguments)
            let gating = gateway.evaluateCallGating(
                entry: entry,
                call: call,
                conversation: conversation,
                configuration: configuration,
                toolPolicy: toolPolicy,
                modePolicyContext: modePolicyContext,
                groupIndex: groupIndex,
                durableRules: configuration.preApprovedToolRules
            )
            gatingAppendix = ToolPolicyGatingExplainAppendix(
                behavior: gating.behavior,
                reasonDescription: describeGatingDecision(gating)
            )
        }

        return ToolPolicyToolExplainRow(
            toolName: entry.name,
            source: entry.source,
            status: status,
            primaryScope: primaryScope,
            primaryDetail: resolvedPrimaryDetail,
            fixItConfigKey: fixIt,
            scopeTrace: trace,
            gatewayBlockReason: gatewayDecision.blockReason,
            gatingAppendix: gatingAppendix
        )
    }

    private static func describeGatingDecision(_ decision: ToolPolicyGatingDecision) -> String {
        switch decision.behavior {
        case .allow:
            if let reason = decision.reason {
                switch reason.kind {
                case .durableGrant:
                    return "Call-level allow (durable grant: \(reason.rule?.rawToken ?? "rule"))."
                case .binding:
                    return "Call-level allow (allow-once binding)."
                default:
                    return "Call-level allow."
                }
            }
            return "Call-level allow."
        case .ask:
            return "Call-level ask (defer to approval / availability)."
        case .deny:
            if let reason = decision.reason, let rule = reason.rule {
                return "Call-level deny (rule `\(rule.rawToken)` in scope `\(reason.scope ?? "unknown")`)."
            }
            return "Call-level deny."
        }
    }

    private static func argumentPreviewJSON(toolName: String, preview: String) -> JSON {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        let canonical = ToolNamePolicyNormalization.canonical(toolName)
        switch canonical {
        case "bash":
            return .object(["command": .string(trimmed)])
        case "read_file", "write_file", "edit":
            return .object(["path": .string(trimmed)])
        case "web_fetch":
            return .object(["url": .string(trimmed)])
        default:
            return .object(["preview": .string(trimmed)])
        }
    }

    private static func firstMatchingNameRule(
        rules: [ToolPolicyRule],
        entry: ToolRegistryEntry,
        groupIndex: ToolPolicyGroupIndex
    ) -> String? {
        for rule in rules where rule.isNameLevelRule {
            if ToolPolicyNameMatcher.matches(
                rule: rule,
                toolName: entry.name,
                entry: entry,
                groupIndex: groupIndex
            ) {
                return rule.rawToken
            }
        }
        return nil
    }

    private static func routingPolicySummary(conversation: ModelConversation) -> String? {
        guard let routingPrefs = conversation.routingPrefs,
              let policy = routingPrefs.explicitToolPolicy else {
            return nil
        }
        switch policy {
        case .allowlist(let tools, _):
            return "Routing allowlist: \(tools.joined(separator: ", "))"
        case .denylist(let tools, _):
            return "Routing denylist: \(tools.joined(separator: ", "))"
        }
    }

    private static func routingToolPolicyPermits(
        toolName: String,
        conversation: ModelConversation,
        groupIndex: ToolPolicyGroupIndex,
        entry: ToolRegistryEntry
    ) -> Bool {
        guard let routingPrefs = conversation.routingPrefs,
              let policy = routingPrefs.explicitToolPolicy else {
            return true
        }
        switch policy {
        case .allowlist(let tools, _):
            if tools.isEmpty { return false }
            let rules = ToolPolicyRulesCache.parseList(tools)
            return ToolPolicyNameMatcher.allowlistPermits(
                rules: rules,
                toolName: toolName,
                entry: entry,
                groupIndex: groupIndex
            )
        case .denylist(let tools, _):
            if tools.isEmpty { return true }
            let rules = ToolPolicyRulesCache.parseList(tools)
            return !ToolPolicyNameMatcher.denylistBlocks(
                rules: rules,
                toolName: toolName,
                entry: entry,
                groupIndex: groupIndex
            )
        }
    }

    private static func hostingRoutingPermits(
        toolName: String,
        conversation: ModelConversation,
        toolPolicy: ToolPolicyConfiguration,
        modePolicyContext: ModePolicyContext,
        groupIndex: ToolPolicyGroupIndex
    ) -> Bool {
        if let modeAllowList = modePolicyContext.resolvedProfile.subAgents.allow {
            let rules = ToolPolicyRulesCache.parseList(modeAllowList)
            if !ToolPolicyNameMatcher.allowlistPermits(
                rules: rules,
                toolName: toolName,
                groupIndex: groupIndex
            ) {
                return false
            }
        }
        let policy = toolPolicy.subAgentHostingPolicy(forDelegateToolName: toolName)
        let metadata = conversation.explainMetadataObject()
        if let requiredHostPersonaID = policy.hostPersonaID, !requiredHostPersonaID.isEmpty {
            let callerHostPersonaID = metadata.explainStringValue(for: "subAgentHostPersonaID")
            guard callerHostPersonaID?.caseInsensitiveCompare(requiredHostPersonaID) == .orderedSame else {
                return false
            }
            if let callerHostPersonaID,
               let hostPolicy = toolPolicy.subAgentHostingPolicy(forHostPersonaID: callerHostPersonaID),
               !hostPolicy.delegationAllowlist.isEmpty {
                let allowed = Set(hostPolicy.delegationAllowlist.map { $0.lowercased() })
                if !allowed.contains(toolName.lowercased()) {
                    return false
                }
            }
        }
        if let routingDomain = policy.routingDomain, !routingDomain.isEmpty {
            let callerRoutingDomain = metadata.explainStringValue(for: "subAgentRoutingDomain")
            guard callerRoutingDomain?.caseInsensitiveCompare(routingDomain) == .orderedSame else {
                return false
            }
        }
        if let tenantScope = policy.tenantScope, !tenantScope.isEmpty {
            let callerTenantScope = metadata.explainStringValue(for: "subAgentTenantScope")
            guard callerTenantScope?.caseInsensitiveCompare(tenantScope) == .orderedSame else {
                return false
            }
        }
        if !policy.authScopeTags.isEmpty {
            let callerScopes = Set(metadata.explainStringArrayValue(for: "subAgentAuthScopeTags").map { $0.lowercased() })
            let requiredScopes = Set(policy.authScopeTags.map { $0.lowercased() })
            if !requiredScopes.isSubset(of: callerScopes) {
                return false
            }
        }
        return true
    }

    private static func delegateDepth(for conversation: ModelConversation) -> Int {
        if conversation.lineageKind == .subAgent {
            return ConversationScope.subAgentDepth(from: conversation.metadata)
        }
        if let metadata = conversation.metadata,
           case .object(let object) = metadata,
           let depthValue = object["subAgentDepth"] {
            switch depthValue {
            case .integer(let depth):
                return max(0, depth)
            case .double(let depth):
                return max(0, Int(depth))
            default:
                break
            }
        }
        return conversation.parentConversationID == nil ? 0 : 1
    }
}

enum ToolPolicyScopeVerdictFormatting {
    static func detailText(for verdict: ToolPolicyScopeVerdict) -> String? {
        switch verdict {
        case .pass:
            return nil
        case .fail(_, let detail, _), .gate(_, let detail):
            return detail
        }
    }
}

private extension ModelConversation {
    func explainMetadataObject() -> [String: JSON] {
        guard let metadata,
              case .object(let object) = metadata else { return [:] }
        return object
    }
}

private extension Dictionary where Key == String, Value == JSON {
    func explainStringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        switch value {
        case .string(let text):
            return text
        default:
            return nil
        }
    }

    func explainStringArrayValue(for key: String) -> [String] {
        guard let value = self[key] else { return [] }
        guard case .array(let array) = value else { return [] }
        return array.compactMap {
            guard case .string(let text) = $0 else { return nil }
            return text
        }
    }
}
