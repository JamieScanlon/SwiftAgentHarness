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

    func callIsReadOnly(entry: ToolRegistryEntry, arguments: JSON) -> Bool

    func evaluateCallAvailability(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        groupIndex: ToolPolicyGroupIndex
    ) -> ToolAvailabilityDecision

    func evaluateAvailability(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        groupIndex: ToolPolicyGroupIndex
    ) -> ToolAvailabilityDecision

    func isHaltingToolCall(
        toolName: String,
        effectiveEntries: [ToolRegistryEntry]
    ) -> Bool

    func evaluateCallGating(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        modePolicyContext: ModePolicyContext,
        groupIndex: ToolPolicyGroupIndex,
        durableRules: [ToolPolicyRule]
    ) -> ToolPolicyGatingDecision

    func evaluateCallApproval(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        parentLookup: @Sendable (UUID) async -> ModelConversation?,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool
}

extension ToolSystemGatewaying {
    func evaluateAvailability(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?
    ) -> ToolAvailabilityDecision {
        evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: modePolicyContext,
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentToolClassifier,
            groupIndex: .empty
        )
    }

    func evaluateCallGating(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        modePolicyContext: ModePolicyContext,
        durableRules: [ToolPolicyRule]
    ) -> ToolPolicyGatingDecision {
        evaluateCallGating(
            entry: entry,
            call: call,
            conversation: conversation,
            configuration: configuration,
            toolPolicy: toolPolicy,
            modePolicyContext: modePolicyContext,
            groupIndex: .empty,
            durableRules: durableRules
        )
    }

    func evaluateCallApproval(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        parentLookup: @Sendable (UUID) async -> ModelConversation?,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool {
        false
    }
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
        let groupIndex = ToolPolicyGroupIndex.build(from: entries)
        return entries.filter { entry in
            let decision = evaluateAvailability(
                entry: entry,
                conversation: conversation,
                modePolicyContext: modePolicyContext,
                configuration: configuration,
                toolPolicy: toolPolicy,
                trustPolicy: trustPolicy,
                subAgentToolClassifier: subAgentToolClassifier,
                groupIndex: groupIndex
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
        } else if effectiveEntries.contains(where: Self.hasUnknownStaticCapabilityMetadata(_:)) {
            parallelDispatchEnabled = false
        } else {
            parallelDispatchEnabled = true
        }
        let resolvedPlannerMode: ToolPolicyConfiguration.DispatchPlannerMode?
        if let configured = toolPolicy.dispatchPlannerMode {
            resolvedPlannerMode = configured
        } else if parallelDispatchEnabled {
            resolvedPlannerMode = .mixedDeterministic
        } else {
            resolvedPlannerMode = nil
        }
        let normalizedPlanner = ToolDispatchPlannerNormalization.effectivePlannerMode(resolvedPlannerMode)
        ToolDispatchPlannerNormalization.warnIfAllParallelRemapped(
            wasRemapped: normalizedPlanner.wasAllParallelRemapped,
            fingerprint: "dispatchContract:\(toolPolicy.stableAllowlistSignature())"
        )
        return AgentRuntimeToolDispatchContract(
            parallelDispatchEnabled: parallelDispatchEnabled,
            dispatchPlannerMode: normalizedPlanner.mode,
            pendingToolTimeoutSeconds: toolPolicy.pendingToolTimeoutSeconds
        )
    }

    func callIsReadOnly(entry: ToolRegistryEntry, arguments: JSON) -> Bool {
        ToolCallCapabilityClassifier.callIsReadOnly(entry: entry, arguments: arguments)
    }

    func evaluateCallAvailability(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        groupIndex: ToolPolicyGroupIndex
    ) -> ToolAvailabilityDecision {
        let turnDecision = evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: modePolicyContext,
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentToolClassifier,
            groupIndex: groupIndex
        )
        guard ToolCallCapabilityClassifier.isPolymorphic(entry.name) else {
            return turnDecision
        }
        if !turnDecision.allowed, turnDecision.blockReason != .approvalRequired {
            return turnDecision
        }
        let executionEnvironmentKind = ToolPolicyConfiguration.ExecutionEnvironmentKind(
            rawValue: entry.executionEnvironment.kind.rawValue
        ) ?? .unknown
        let executionEnvironmentAdapterID = entry.executionEnvironment.adapterID
        let callIsReadOnly = callIsReadOnly(entry: entry, arguments: call.arguments)
        let callRequiresApproval = toolPolicy.requiresApproval(
            toolName: entry.name,
            context: modePolicyContext,
            toolIsReadOnly: callIsReadOnly,
            entryRequiresApprovalTag: entry.policyTags.contains(.requiresApproval)
        ) || toolPolicy.requiresExecutionEnvironmentApproval(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterApproval(adapterID: executionEnvironmentAdapterID)
        let approvalRequiredFinal = callRequiresApproval || turnDecision.isElevated
            || (turnDecision.delegationPermissionPolicy != nil && turnDecision.delegationPermissionPolicy != .auto)
        let approvalGranted = turnDecision.approvalGranted
            || ToolCallApprovalPolicy.isBindingPreApproved(call: call, configuration: configuration)
        if approvalRequiredFinal, !approvalGranted {
            return .blocked(
                .approvalRequired,
                facts: AvailabilityFacts(
                    isSensitive: turnDecision.isSensitive,
                    requiresEscalation: turnDecision.requiresEscalation,
                    requiresApproval: true,
                    isElevated: turnDecision.isElevated,
                    approvalGranted: false,
                    approvalRoute: turnDecision.approvalRoute,
                    delegationPermissionPolicy: turnDecision.delegationPermissionPolicy,
                    delegationTrustLevel: turnDecision.delegationTrustLevel
                )
            )
        }
        if turnDecision.allowed {
            return turnDecision
        }
        return .allowed(
            AvailabilityFacts(
                isSensitive: turnDecision.isSensitive,
                requiresEscalation: turnDecision.requiresEscalation,
                requiresApproval: approvalRequiredFinal,
                isElevated: turnDecision.isElevated,
                approvalGranted: approvalGranted,
                approvalRoute: turnDecision.approvalRoute,
                delegationPermissionPolicy: turnDecision.delegationPermissionPolicy,
                delegationTrustLevel: turnDecision.delegationTrustLevel
            )
        )
    }

    func evaluateAvailability(
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        modePolicyContext: ModePolicyContext,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicy: TrustPolicyConfiguration,
        subAgentToolClassifier: (any SubAgentToolClassifying)?,
        groupIndex: ToolPolicyGroupIndex
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
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID,
                    groupIndex: groupIndex
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
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID,
                    groupIndex: groupIndex
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
                    executionEnvironmentAdapterID: executionEnvironmentAdapterID,
                    groupIndex: groupIndex
                )
            )
        }
        let isSensitive = toolPolicy.isToolSensitive(name: entry.name, groupIndex: groupIndex)
        let escalationRequired = toolPolicy.requiresEscalation(name: entry.name, groupIndex: groupIndex)
            || toolPolicy.requiresExecutionEnvironmentEscalation(kind: executionEnvironmentKind)
            || toolPolicy.requiresExecutionEnvironmentAdapterEscalation(adapterID: executionEnvironmentAdapterID)
        let toolIsReadOnly = Self.toolIsReadOnlyForTurnLevelApproval(entry: entry)
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
        let approvalGranted = ToolNamePolicyNormalization.setContains(
            configuration.preApprovedToolNames,
            name: entry.name
        )
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
                modePolicyContext: modePolicyContext,
                groupIndex: groupIndex
           ) {
            return .blocked(.hostingRoutingPolicyDenied, facts: facts)
        }
        if toolPolicy.isToolDenied(
            name: entry.name,
            context: modePolicyContext,
            groupIndex: groupIndex,
            entry: entry
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
            context: modePolicyContext,
            groupIndex: groupIndex,
            entry: entry
        ) {
            return .blocked(.promptConfigAllowlist, facts: facts)
        }
        if !isAllowedByRoutingToolPolicy(
            toolName: entry.name,
            conversation: conversation,
            groupIndex: groupIndex,
            entry: entry
        ) {
            return .blocked(.routingToolWhitelist, facts: facts)
        }
        return .allowed(facts)
    }

    func evaluateCallGating(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        toolPolicy: ToolPolicyConfiguration,
        modePolicyContext: ModePolicyContext,
        groupIndex: ToolPolicyGroupIndex,
        durableRules: [ToolPolicyRule]
    ) -> ToolPolicyGatingDecision {
        let bindingPreApproved = ToolCallApprovalPolicy.isBindingPreApproved(
            call: call,
            configuration: configuration
        )
        let modeDeny = ToolPolicyRulesCache.parseList(modePolicyContext.resolvedProfile.tools.deny)
        let modeAllow = modePolicyContext.resolvedProfile.tools.allow.flatMap {
            ToolPolicyRulesCache.parseList($0)
        }
        let scopes = [
            ToolPolicyGatingScope(name: "durable", autoAllowRules: durableRules),
            ToolPolicyGatingScope(name: "mode-deny", denyRules: modeDeny),
            ToolPolicyGatingScope(name: "mode-allow", allowRules: modeAllow),
        ]
        return ToolPolicyGatingEvaluator.evaluate(
            entry: entry,
            arguments: call.arguments,
            groupIndex: groupIndex,
            scopes: scopes,
            bindingPreApproved: bindingPreApproved
        )
    }

    func isHaltingToolCall(
        toolName: String,
        effectiveEntries: [ToolRegistryEntry]
    ) -> Bool {
        effectiveEntries.contains { entry in
            entry.haltsLoop
                && ToolNamePolicyNormalization.matchesRegistryName(
                    callName: toolName,
                    entryName: entry.name
                )
        }
    }

    func evaluateCallApproval(
        entry: ToolRegistryEntry,
        call: ToolCallRequest,
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration,
        parentLookup: @Sendable (UUID) async -> ModelConversation?,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool {
        guard entry.name == "schedule_create" else { return false }
        return await ScheduleCreateApprovalPolicy.requiresApproval(
            arguments: call.arguments,
            callerConversationID: conversation.id,
            parentLookup: parentLookup,
            tenancyPolicy: tenancyPolicy
        )
    }

    private static func earlyDenyFacts(
        entry: ToolRegistryEntry,
        modePolicyContext: ModePolicyContext,
        toolPolicy: ToolPolicyConfiguration,
        executionEnvironmentKind: ToolPolicyConfiguration.ExecutionEnvironmentKind,
        executionEnvironmentAdapterID: String,
        groupIndex: ToolPolicyGroupIndex
    ) -> AvailabilityFacts {
        let toolIsReadOnly = Self.toolIsReadOnlyForTurnLevelApproval(entry: entry)
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
        return AvailabilityFacts(
            isSensitive: toolPolicy.isToolSensitive(name: entry.name, groupIndex: groupIndex),
            requiresEscalation: toolPolicy.requiresEscalation(name: entry.name, groupIndex: groupIndex)
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
        modePolicyContext: ModePolicyContext,
        groupIndex: ToolPolicyGroupIndex
    ) -> Bool {
        if !isAllowedByModeSubAgentAllowList(
            toolName: toolName,
            modeAllowList: modePolicyContext.resolvedProfile.subAgents.allow,
            groupIndex: groupIndex
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
        modeAllowList: [String]?,
        groupIndex: ToolPolicyGroupIndex
    ) -> Bool {
        guard let modeAllowList else { return true }
        let rules = ToolPolicyRulesCache.parseList(modeAllowList)
        return ToolPolicyNameMatcher.allowlistPermits(
            rules: rules,
            toolName: toolName,
            groupIndex: groupIndex
        )
    }

    private func isAllowedByRoutingToolPolicy(
        toolName: String,
        conversation: ModelConversation,
        groupIndex: ToolPolicyGroupIndex,
        entry: ToolRegistryEntry?
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

    private static func hasUnknownStaticCapabilityMetadata(_ entry: ToolRegistryEntry) -> Bool {
        entry.effectClass == .unknown || entry.parallelHint == .unknown
    }

    private static func toolIsReadOnlyForTurnLevelApproval(entry: ToolRegistryEntry) -> Bool {
        if ToolCallCapabilityClassifier.isPolymorphic(entry.name) {
            return true
        }
        return entry.effectClass == .readOnly
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
