import Foundation
import EasyJSON
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

struct AvailabilityFacts: Sendable, Equatable {
    let isSensitive: Bool
    let requiresEscalation: Bool
    let requiresApproval: Bool
    let isElevated: Bool
    let approvalGranted: Bool
    let approvalRoute: ToolApprovalRoute?
    let delegationPermissionPolicy: SubAgentPermissionPolicy?
    let delegationTrustLevel: SubAgentTrustLevel?
}

struct ToolAvailabilityDecision: Sendable, Equatable {
    let allowed: Bool
    let blockReason: ToolAvailabilityBlockReason?
    let isSensitive: Bool
    let requiresEscalation: Bool
    let requiresApproval: Bool
    let isElevated: Bool
    let approvalGranted: Bool
    let approvalRoute: ToolApprovalRoute?
    let delegationPermissionPolicy: SubAgentPermissionPolicy?
    let delegationTrustLevel: SubAgentTrustLevel?

    static let allowedDefault = ToolAvailabilityDecision(
        allowed: true,
        blockReason: nil,
        isSensitive: false,
        requiresEscalation: false,
        requiresApproval: false,
        isElevated: false,
        approvalGranted: false,
        approvalRoute: nil,
        delegationPermissionPolicy: nil,
        delegationTrustLevel: nil
    )

    var isAdvertisedToModel: Bool {
        allowed || blockReason == .approvalRequired
    }

    static func blocked(_ reason: ToolAvailabilityBlockReason, facts: AvailabilityFacts) -> Self {
        Self(
            allowed: false,
            blockReason: reason,
            isSensitive: facts.isSensitive,
            requiresEscalation: facts.requiresEscalation,
            requiresApproval: facts.requiresApproval,
            isElevated: facts.isElevated,
            approvalGranted: reason == .approvalRequired ? false : facts.approvalGranted,
            approvalRoute: facts.approvalRoute,
            delegationPermissionPolicy: facts.delegationPermissionPolicy,
            delegationTrustLevel: facts.delegationTrustLevel
        )
    }

    static func allowed(_ facts: AvailabilityFacts) -> Self {
        Self(
            allowed: true,
            blockReason: nil,
            isSensitive: facts.isSensitive,
            requiresEscalation: facts.requiresEscalation,
            requiresApproval: facts.requiresApproval,
            isElevated: facts.isElevated,
            approvalGranted: facts.approvalGranted,
            approvalRoute: facts.approvalRoute,
            delegationPermissionPolicy: facts.delegationPermissionPolicy,
            delegationTrustLevel: facts.delegationTrustLevel
        )
    }
}

protocol ToolSystemGatewaying: Sendable {
    func allRegisteredToolsForTurn(
        orchestrator: SwiftAgentKitOrchestrator,
        dataProvider: ConversationsDataProviding,
        logger: Logger?
    ) async -> [ToolRegistryEntry]

    func effectiveToolsForConversation(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [ToolDefinition]

    func effectiveEntriesForConversation(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [ToolRegistryEntry]

    func availableToolsForAPI(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [AvailableToolInfo]

    func dispatchContract(
        from toolPolicy: ToolPolicyConfiguration,
        effectiveEntries: [ToolRegistryEntry]
    ) -> AgentRuntimeToolDispatchContract

    func evaluateAvailability(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> ToolAvailabilityDecision

    func isHaltingToolCall(
        toolName: String,
        effectiveEntries: [ToolRegistryEntry]
    ) -> Bool
}

struct DefaultToolSystemGateway: ToolSystemGatewaying {
    func allRegisteredToolsForTurn(
        orchestrator: SwiftAgentKitOrchestrator,
        dataProvider: ConversationsDataProviding,
        logger: Logger?
    ) async -> [ToolRegistryEntry] {
        let descriptors = await OrchestrationToolCatalog.allRegisteredToolDescriptorsForOrchestration(
            orchestrator: orchestrator,
            dataProvider: dataProvider,
            logger: logger
        )
        return OrchestrationToolCatalog.registryEntries(from: descriptors)
    }

    func effectiveToolsForConversation(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [ToolDefinition] {
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: configuration.inputTrustRaw,
                unknownFallback: trustPolicy.safeDefaultClass
            )
        if trustPolicy.shouldGateExecution(for: trustClass) {
            return []
        }
        guard configuration.enableTools else { return [] }

        return effectiveEntriesForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modePolicyContext,
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentToolClassifier
        ).map(\.definition).sorted { $0.name < $1.name }
    }

    func effectiveEntriesForConversation(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [ToolRegistryEntry] {
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: configuration.inputTrustRaw,
                unknownFallback: trustPolicy.safeDefaultClass
            )
        if trustPolicy.shouldGateExecution(for: trustClass) {
            return []
        }
        guard configuration.enableTools else { return [] }
        return entries.filter { entry in
            let decision = evaluateAvailability(
                entry: entry,
                conversation: conversation,
                modePolicyContext: modePolicyContext,
                configuration: configuration,
                toolPolicy: toolPolicy,
                trustPolicy: trustPolicy,
                subAgentToolClassifier: subAgentToolClassifier
            )
            return decision.isAdvertisedToModel
        }.sorted { $0.name < $1.name }
    }

    func availableToolsForAPI(
        entries: [ToolRegistryEntry],
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> [AvailableToolInfo] {
        let eligible = effectiveEntriesForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modePolicyContext,
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentToolClassifier
        )
        return OrchestrationToolCatalog.availableToolInfos(from: eligible)
    }

    func dispatchContract(
        from toolPolicy: ToolPolicyConfiguration,
        effectiveEntries: [ToolRegistryEntry]
    ) -> AgentRuntimeToolDispatchContract {
        let parallelDispatchEnabled: Bool
        if !toolPolicy.parallelDispatchEnabled {
            parallelDispatchEnabled = false
        } else if effectiveEntries.isEmpty {
            parallelDispatchEnabled = false
        } else {
            parallelDispatchEnabled = effectiveEntries.allSatisfy(Self.isParallelSafeEntry(_:))
        }
        return AgentRuntimeToolDispatchContract(
            parallelDispatchEnabled: parallelDispatchEnabled,
            dispatchPlannerMode: toolPolicy.dispatchPlannerMode,
            pendingToolTimeoutSeconds: toolPolicy.pendingToolTimeoutSeconds
        )
    }

    func evaluateAvailability(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> ToolAvailabilityDecision {
        let executionEnvironmentKind = ToolPolicyConfiguration.ExecutionEnvironmentKind(
            rawValue: entry.executionEnvironment.kind.rawValue
        ) ?? .unknown
        let executionEnvironmentAdapterID = entry.executionEnvironment.adapterID
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: configuration.inputTrustRaw,
                unknownFallback: trustPolicy.safeDefaultClass
            )
        if trustPolicy.shouldGateExecution(for: trustClass) {
            return .blocked(
                .toolsDisabledForSend,
                facts: Self.earlyDenyFacts(
                    entry: entry,
                    modePolicyContext: modePolicyContext,
                    toolPolicy: toolPolicy,
                    executionEnvironmentKind: executionEnvironmentKind,
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID
                )
            )
        }
        guard configuration.enableTools else {
            return .blocked(
                .toolsDisabledForSend,
                facts: Self.earlyDenyFacts(
                    entry: entry,
                    modePolicyContext: modePolicyContext,
                    toolPolicy: toolPolicy,
                    executionEnvironmentKind: executionEnvironmentKind,
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID
                )
            )
        }
        if !toolPolicy.isExecutionEnvironmentAllowed(kind: executionEnvironmentKind)
            || !toolPolicy.isExecutionEnvironmentAdapterAllowed(adapterID: executionEnvironmentAdapterID) {
            return .blocked(
                .executionEnvironmentPolicyDenied,
                facts: Self.earlyDenyFacts(
                    entry: entry,
                    modePolicyContext: modePolicyContext,
                    toolPolicy: toolPolicy,
                    executionEnvironmentKind: executionEnvironmentKind,
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID
                )
            )
        }
        let isSensitive = toolPolicy.isToolSensitive(name: entry.name)
        let escalationRequired = toolPolicy.requiresEscalation(name: entry.name)
            || toolPolicy.requiresExecutionEnvironmentEscalation(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterEscalation(adapterID: executionEnvironmentAdapterID)
        let toolIsReadOnly = entry.effectClass == .readOnly
        let requiresApproval = toolPolicy.requiresApproval(
            toolName: entry.name,
            context: modePolicyContext,
            toolIsReadOnly: toolIsReadOnly,
            entryRequiresApprovalTag: entry.policyTags.contains(.requiresApproval)
        ) || toolPolicy.requiresExecutionEnvironmentApproval(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterApproval(adapterID: executionEnvironmentAdapterID)
        let isElevated = (toolPolicy.isElevatedTool(name: entry.name)
            || entry.policyTags.contains(.elevated))
            && !toolPolicy.isPerCallElevatedTool(name: entry.name)
        let approvalRequiredByPolicy = requiresApproval || isElevated
        let isDelegateTool = subAgentToolClassifier?.isDelegateTool(entry: entry) ?? (entry.source == .a2a)
        let delegatePermissionPolicy = isDelegateTool ? (subAgentToolClassifier?.permissionPolicy(for: entry) ?? .askUser) : nil
        let delegateTrustLevel = isDelegateTool ? (subAgentToolClassifier?.trustLevel(for: entry) ?? .unknownParty) : nil
        let approvalRoute: ToolApprovalRoute? = {
            guard let delegatePermissionPolicy else { return nil }
            switch delegatePermissionPolicy {
            case .auto:
                return nil
            case .askParent:
                return .parent
            case .askUser:
                return .user
            }
        }()
        let approvalRequiredByDelegationRoute = isDelegateTool && delegatePermissionPolicy != .auto
        let approvalRequiredFinal = approvalRequiredByPolicy || approvalRequiredByDelegationRoute
        let approvalGranted = configuration.preApprovedToolNames.contains(entry.name)
        let facts = AvailabilityFacts(
            isSensitive: isSensitive,
            requiresEscalation: escalationRequired,
            requiresApproval: approvalRequiredFinal,
            isElevated: isElevated,
            approvalGranted: approvalGranted,
            approvalRoute: approvalRoute,
            delegationPermissionPolicy: delegatePermissionPolicy,
            delegationTrustLevel: delegateTrustLevel
        )
        if isDelegateTool,
           let maxRecursionDepth = subAgentToolClassifier?.maxRecursionDepth(for: entry),
           delegateDepth(for: conversation) >= maxRecursionDepth {
            return .blocked(.recursionDepthExceeded, facts: facts)
        }
        if !configuration.enableAgents, isDelegateTool {
            return .blocked(.agentsDisabledForRemoteAgentTool, facts: facts)
        }
        if isDelegateTool,
           !isAllowedByHostingRoutingPolicy(
                toolName: entry.name,
                conversation: conversation,
                toolPolicy: toolPolicy,
                modePolicyContext: modePolicyContext
           ) {
            return .blocked(.hostingRoutingPolicyDenied, facts: facts)
        }
        if toolPolicy.isToolDenied(
            name: entry.name,
            context: modePolicyContext
        ) {
            return .blocked(.promptConfigDenylist, facts: facts)
        }
        if escalationRequired, !configuration.allowEscalatedTools {
            return .blocked(.escalationRequired, facts: facts)
        }
        if approvalRequiredFinal, !approvalGranted {
            return .blocked(.approvalRequired, facts: facts)
        }
        if !toolPolicy.isToolAllowed(
            name: entry.name,
            context: modePolicyContext
        ) {
            return .blocked(.promptConfigAllowlist, facts: facts)
        }
        if !isAllowedByRoutingToolPolicy(
            toolName: entry.name,
            conversation: conversation
        ) {
            return .blocked(.routingToolWhitelist, facts: facts)
        }
        return .allowed(facts)
    }

    func isHaltingToolCall(
        toolName: String,
        effectiveEntries: [ToolRegistryEntry]
    ) -> Bool {
        effectiveEntries.contains { entry in
            entry.haltsLoop
                && entry.name.caseInsensitiveCompare(toolName) == .orderedSame
        }
    }

    private static func earlyDenyFacts(
        entry: ToolRegistryEntry,
        modePolicyContext: ModePolicyContext,
        toolPolicy: ToolPolicyConfiguration,
        executionEnvironmentKind: ToolPolicyConfiguration.ExecutionEnvironmentKind,
        executionEnvironmentAdapterID: String
    ) -> AvailabilityFacts {
        let toolIsReadOnly = entry.effectClass == .readOnly
        let requiresApproval = toolPolicy.requiresApproval(
            toolName: entry.name,
            context: modePolicyContext,
            toolIsReadOnly: toolIsReadOnly,
            entryRequiresApprovalTag: entry.policyTags.contains(.requiresApproval)
        ) || toolPolicy.requiresExecutionEnvironmentApproval(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterApproval(adapterID: executionEnvironmentAdapterID)
        let isElevated = (toolPolicy.isElevatedTool(name: entry.name)
            || entry.policyTags.contains(.elevated))
            && !toolPolicy.isPerCallElevatedTool(name: entry.name)
        return AvailabilityFacts(
            isSensitive: toolPolicy.isToolSensitive(name: entry.name),
            requiresEscalation: toolPolicy.requiresEscalation(name: entry.name)
                || toolPolicy.requiresExecutionEnvironmentEscalation(kind: executionEnvironmentKind)
                || toolPolicy.requiresExecutionEnvironmentAdapterEscalation(adapterID: executionEnvironmentAdapterID),
            requiresApproval: requiresApproval,
            isElevated: isElevated,
            approvalGranted: false,
            approvalRoute: nil,
            delegationPermissionPolicy: nil,
            delegationTrustLevel: nil
        )
    }

    private func delegateDepth(for conversation: ModelConversation) -> Int {
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

    private func isAllowedByHostingRoutingPolicy(
        toolName: String,
        conversation: ModelConversation,
        toolPolicy: ToolPolicyConfiguration,
        modePolicyContext: ModePolicyContext
    ) -> Bool {
        if !isAllowedByModeSubAgentAllowList(
            toolName: toolName,
            modeAllowList: modePolicyContext.resolvedProfile.subAgents.allow
        ) {
            return false
        }
        let policy = toolPolicy.subAgentHostingPolicy(forDelegateToolName: toolName)
        let metadata = conversation.metadataObject()
        if let requiredHostPersonaID = policy.hostPersonaID, !requiredHostPersonaID.isEmpty {
            let callerHostPersonaID = metadata.stringValue(for: "subAgentHostPersonaID")
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
            let callerRoutingDomain = metadata.stringValue(for: "subAgentRoutingDomain")
            guard callerRoutingDomain?.caseInsensitiveCompare(routingDomain) == .orderedSame else {
                return false
            }
        }
        if let tenantScope = policy.tenantScope, !tenantScope.isEmpty {
            let callerTenantScope = metadata.stringValue(for: "subAgentTenantScope")
            guard callerTenantScope?.caseInsensitiveCompare(tenantScope) == .orderedSame else {
                return false
            }
        }
        if !policy.authScopeTags.isEmpty {
            let callerScopes = Set(metadata.stringArrayValue(for: "subAgentAuthScopeTags").map { $0.lowercased() })
            let requiredScopes = Set(policy.authScopeTags.map { $0.lowercased() })
            if !requiredScopes.isSubset(of: callerScopes) {
                return false
            }
        }
        return true
    }

    private func isAllowedByModeSubAgentAllowList(
        toolName: String,
        modeAllowList: [String]?
    ) -> Bool {
        guard let modeAllowList else { return true }
        let normalized = Set(modeAllowList.map { $0.lowercased() })
        if normalized.contains("*") {
            return true
        }
        return normalized.contains(toolName.lowercased())
    }

    private func isAllowedByRoutingToolPolicy(
        toolName: String,
        conversation: ModelConversation
    ) -> Bool {
        guard let routingPrefs = conversation.routingPrefs,
              let policy = routingPrefs.explicitToolPolicy else {
            return true
        }
        switch policy {
        case .allowlist(let tools, _):
            if tools.isEmpty { return false }
            if tools.contains("*") { return true }
            return tools.contains(toolName)
        case .denylist(let tools, _):
            if tools.isEmpty { return true }
            if tools.contains("*") { return false }
            return !tools.contains(toolName)
        }
    }

    private static func isParallelSafeEntry(_ entry: ToolRegistryEntry) -> Bool {
        entry.effectClass == .readOnly && entry.parallelHint == .parallelizable
    }
}

private extension ModelConversation {
    func metadataObject() -> [String: JSON] {
        guard let metadata,
              case .object(let object) = metadata else { return [:] }
        return object
    }
}

private extension Dictionary where Key == String, Value == JSON {
    func stringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        switch value {
        case .string(let text):
            return text
        default:
            return nil
        }
    }

    func stringArrayValue(for key: String) -> [String] {
        guard let value = self[key] else { return [] }
        guard case .array(let array) = value else { return [] }
        return array.compactMap {
            guard case .string(let text) = $0 else { return nil }
            return text
        }
    }
}
