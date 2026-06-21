import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension OrchestratorRuntimeService {
    struct ExecutionDispatchContext: Sendable {
        let executionEnvironmentKind: String
        let executionEnvironmentAdapterID: String
        let executionIsolationLevel: String
    }

    actor ToolSystemLivePreDispatchPolicyEvaluator: ToolPreDispatchPolicyEvaluating {
        private let gateway: any ToolSystemGatewaying
        private let deps: ConversationRuntimeDependencies
        private let modePolicy: any OrchestratorModePolicyProviding
        private let toolApproval: any ToolApprovalRuntimeServicing
        private let subAgentPool: any SubAgentPooling
        private let persistenceDomain: ConversationPersistenceDomain
        private let resolveOrchestrator: @Sendable () async -> SwiftAgentKitOrchestrator?
        private let resolveToolData: @Sendable () async -> ConversationsDataProviding
        private let resolveActiveTurnConfiguration: @Sendable (UUID, UUID?) async -> AgentRuntimeTurnConfiguration?
        private let logger: Logger?

        init(
            gateway: any ToolSystemGatewaying,
            deps: ConversationRuntimeDependencies,
            modePolicy: any OrchestratorModePolicyProviding,
            toolApproval: any ToolApprovalRuntimeServicing,
            subAgentPool: any SubAgentPooling,
            persistenceDomain: ConversationPersistenceDomain,
            resolveOrchestrator: @escaping @Sendable () async -> SwiftAgentKitOrchestrator?,
            resolveToolData: @escaping @Sendable () async -> ConversationsDataProviding,
            resolveActiveTurnConfiguration: @escaping @Sendable (UUID, UUID?) async -> AgentRuntimeTurnConfiguration?,
            logger: Logger?
        ) {
            self.gateway = gateway
            self.deps = deps
            self.modePolicy = modePolicy
            self.toolApproval = toolApproval
            self.subAgentPool = subAgentPool
            self.persistenceDomain = persistenceDomain
            self.resolveOrchestrator = resolveOrchestrator
            self.resolveToolData = resolveToolData
            self.resolveActiveTurnConfiguration = resolveActiveTurnConfiguration
            self.logger = logger
        }

        func decide(_ context: ToolPreDispatchPolicyContext) async -> ToolPreDispatchPolicyDecision {
            let requestedName = context.request.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestedName.isEmpty else {
                return Self.unavailableDecision()
            }
            guard let conversationIDString = context.request.conversationID,
                  let conversationID = UUID(uuidString: conversationIDString),
                  let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
                return Self.unavailableDecision()
            }
            let runID = context.request.runID.flatMap(UUID.init(uuidString:))
            let baseManagerConfig: HarnessRuntimeSession.Configuration
            if let active = await resolveActiveTurnConfiguration(conversationID, runID) {
                baseManagerConfig = HarnessRuntimeSession.Configuration(runtimeConfiguration: active)
            } else {
                baseManagerConfig = HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
            }
            let policyConfiguration = await toolApproval.configurationApplyingToolApprovals(
                baseManagerConfig,
                conversationID: conversationID,
                runID: runID
            )
            let runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: policyConfiguration)
            let modeCtx = await modePolicy.modePolicyContext(for: conversation)
            let entry: ToolRegistryEntry
            if let orchestrator = await resolveOrchestrator() {
                let entries = await gateway.allRegisteredToolsForTurn(
                    orchestrator: orchestrator,
                    dataProvider: await resolveToolData(),
                    logger: logger
                )
                guard let resolved = entries.first(where: { $0.name.caseInsensitiveCompare(requestedName) == .orderedSame }) else {
                    return Self.unavailableDecision()
                }
                entry = resolved
            } else if let descriptor = context.descriptor {
                entry = ToolRegistryEntry(descriptor: descriptor)
            } else {
                return Self.unavailableDecision()
            }
            let decision = gateway.evaluateAvailability(
                entry: entry,
                conversation: conversation,
                modePolicyContext: modeCtx,
                configuration: runtimeConfiguration,
                toolPolicy: deps.toolPolicy,
                trustPolicy: deps.trustPolicyConfiguration,
                subAgentToolClassifier: subAgentPool
            )
            return Self.mapAvailabilityDecision(
                decision,
                dispatchContext: OrchestratorRuntimeService.executionDispatchContext(for: entry),
                elevatedExecutionPolicy: deps.toolPolicy.elevatedExecutionPolicy,
                approvalContractSpec: toolApproval.approvalContractSpec(
                    toolName: entry.name,
                    route: decision.approvalRoute ?? .user,
                    isElevated: decision.isElevated
                )
            )
        }

        private static func unavailableDecision() -> ToolPreDispatchPolicyDecision {
            ToolPreDispatchPolicyDecision(
                decision: .deny,
                reasonCode: "tool_not_available",
                reasonText: "Tool is not available for this invocation."
            )
        }

        private static func mapAvailabilityDecision(
            _ decision: ToolAvailabilityDecision,
            dispatchContext: ExecutionDispatchContext,
            elevatedExecutionPolicy: ToolPolicyConfiguration.ElevatedExecutionPolicy,
            approvalContractSpec: ToolApprovalContractSpec
        ) -> ToolPreDispatchPolicyDecision {
            if decision.allowed {
                if decision.isElevated {
                    return ToolPreDispatchPolicyDecision(
                        decision: .elevated,
                        reasonCode: "elevated.\(elevatedExecutionPolicy.rawValue)",
                        reasonText: "Tool executes under elevated policy '\(elevatedExecutionPolicy.rawValue)' in environment '\(dispatchContext.executionEnvironmentKind)'."
                    )
                }
                return ToolPreDispatchPolicyDecision(decision: .allow)
            }
            if decision.blockReason == .approvalRequired {
                return ToolPreDispatchPolicyDecision(
                    decision: .requireApproval,
                    reasonCode: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                    reasonText: "Tool requires explicit approval before execution.",
                    approvalSpec: ToolApprovalSpec(
                        title: approvalContractSpec.title,
                        description: approvalContractSpec.description,
                        severity: approvalContractSpec.severity,
                        timeoutMs: approvalContractSpec.timeoutMs,
                        timeoutBehavior: approvalContractSpec.timeoutBehavior.rawValue
                    )
                )
            }
            return ToolPreDispatchPolicyDecision(
                decision: .deny,
                reasonCode: decision.blockReason?.rawValue ?? "blocked",
                reasonText: "Tool blocked by availability policy for environment '\(dispatchContext.executionEnvironmentKind)'."
            )
        }
    }

    static func executionDispatchContext(for entry: ToolRegistryEntry) -> ExecutionDispatchContext {
        ExecutionDispatchContext(
            executionEnvironmentKind: entry.executionEnvironment.kind.rawValue,
            executionEnvironmentAdapterID: entry.executionEnvironment.adapterID,
            executionIsolationLevel: entry.executionEnvironment.isolationLevel.rawValue
        )
    }

    func executionDispatchContext(for entry: ToolRegistryEntry) -> ExecutionDispatchContext {
        Self.executionDispatchContext(for: entry)
    }

    func approvalContractSpec(
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool
    ) async -> ToolApprovalContractSpec {
        installedToolApproval.approvalContractSpec(toolName: toolName, route: route, isElevated: isElevated)
    }

    func effectiveAvailableToolEntries(
        allEntries: [ToolRegistryEntry],
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration
    ) async -> [ToolRegistryEntry] {
        let runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: configuration)
        let modeCtx = await installedModePolicy.modePolicyContext(for: conversation)
        return toolSystemGateway.effectiveEntriesForConversation(
            entries: allEntries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: runtimeConfiguration,
            toolPolicy: deps.toolPolicy,
            trustPolicy: deps.trustPolicyConfiguration,
            subAgentToolClassifier: subAgentPool
        )
    }

    func toolAvailabilitySnapshots(
        allEntries: [ToolRegistryEntry],
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration
    ) async -> [RuntimeToolAvailabilitySnapshot] {
        let modeCtx = await installedModePolicy.modePolicyContext(for: conversation)
        let runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: configuration)
        return allEntries
            .map { entry in
                RuntimeToolAvailabilitySnapshot(
                    entry: entry,
                    decision: toolSystemGateway.evaluateAvailability(
                        entry: entry,
                        conversation: conversation,
                        modePolicyContext: modeCtx,
                        configuration: runtimeConfiguration,
                        toolPolicy: deps.toolPolicy,
                        trustPolicy: deps.trustPolicyConfiguration,
                        subAgentToolClassifier: subAgentPool
                    )
                )
            }
            .sorted { $0.entry.name < $1.entry.name }
    }

    func buildToolTurnPolicySnapshot(
        allEntries: [ToolRegistryEntry],
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration
    ) async -> RuntimeToolTurnPolicySnapshot {
        let availabilitySnapshots = await toolAvailabilitySnapshots(
            allEntries: allEntries,
            conversation: conversation,
            configuration: configuration
        )
        let effectiveEntries = availabilitySnapshots
            .filter { $0.decision.isAdvertisedToModel }
            .map(\.entry)
            .sorted { $0.name < $1.name }
        let allowedEntries = availabilitySnapshots
            .filter { $0.decision.allowed }
            .map(\.entry)
            .sorted { $0.name < $1.name }
        let dispatchContract = toolSystemGateway.dispatchContract(
            from: deps.toolPolicy,
            effectiveEntries: allowedEntries
        )
        await installTurnToolRegistryEntriesForRuntimeMiddleware(effectiveEntries)
        return RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: availabilitySnapshots,
            effectiveEntries: effectiveEntries,
            dispatchContract: dispatchContract
        )
    }
}
