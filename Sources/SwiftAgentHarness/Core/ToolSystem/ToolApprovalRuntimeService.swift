import Foundation
import SwiftAgentKit

actor ToolApprovalRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let topics: ConversationTopicPublicationPort
    nonisolated(unsafe) private var subAgentSpawnService: SubAgentSpawnService!
    private let stateStore = ToolApprovalStateStore()
    private let permissionRules: any PermissionRuleStore

    init(
        deps: ConversationRuntimeDependencies,
        topics: ConversationTopicPublicationPort,
        permissionRules: any PermissionRuleStore = InMemoryPermissionRuleStore()
    ) {
        self.deps = deps
        self.topics = topics
        self.permissionRules = permissionRules
    }

    /// Persists an `allow-always` rule for a tool so future runs (and restarts when
    /// the store is disk-backed) auto-approve it.
    func grantDurableToolRule(toolName: String) async {
        await permissionRules.add(.toolName(toolName))
    }

    /// Lists persisted durable tool-name grants, sorted ascending.
    func listDurableToolGrants() async -> [String] {
        await permissionRules.grantedToolNames().sorted()
    }

    /// Revokes a persisted durable tool-name grant.
    func revokeDurableToolGrant(toolName: String) async {
        await permissionRules.remove(.toolName(toolName))
    }

    nonisolated func installSubAgentSpawnService(_ subAgentSpawnService: SubAgentSpawnService) {
        precondition(self.subAgentSpawnService == nil, "SubAgentSpawnService already installed")
        self.subAgentSpawnService = subAgentSpawnService
    }

    private var installedSubAgentSpawnService: SubAgentSpawnService {
        guard let subAgentSpawnService else {
            preconditionFailure("SubAgentSpawnService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return subAgentSpawnService
    }

    func approvalRouteForConversation(conversationID: UUID) async -> ToolApprovalRoute {
        if let conversation = await deps.persistenceDomain.modelConversation(id: conversationID),
           conversation.parentConversationID != nil {
            return .parent
        }
        return .user
    }

    func configurationApplyingToolApprovals(
        _ configuration: HarnessRuntimeSession.Configuration,
        conversationID: UUID,
        runID: UUID?
    ) async -> HarnessRuntimeSession.Configuration {
        var out = configuration
        let route = await approvalRouteForConversation(conversationID: conversationID)
        let storeApproved = await stateStore.approvedToolNames(
            conversationID: conversationID,
            runID: runID,
            route: route
        )
        out.preApprovedToolNames.formUnion(storeApproved)
        // Durable `allow-always` tool grants apply across runs (and restarts when the
        // permission rule store is disk-backed).
        out.preApprovedToolNames.formUnion(await permissionRules.grantedToolNames())
        return out
    }

    nonisolated func approvalContractSpec(
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool
    ) -> ToolApprovalContractSpec {
        let severity = isElevated
            ? deps.toolPolicy.approvalElevatedSeverityDefault
            : deps.toolPolicy.approvalSeverityDefault
        let title = isElevated ? "Elevated Tool Approval Required" : "Tool Approval Required"
        let description = "Approve \(toolName) for this run (route: \(route.rawValue))."
        let presentation = ApprovalPresentation.standard(
            title: title,
            context: [
                "Tool: \(toolName)",
                "Route: \(route.rawValue)  Severity: \(severity)",
                isElevated ? "This tool runs with elevated privileges." : "",
            ]
        )
        return ToolApprovalContractSpec(
            title: title,
            description: description,
            severity: severity,
            timeoutMs: deps.toolPolicy.approvalTimeoutMilliseconds,
            timeoutBehavior: deps.toolPolicy.approvalTimeoutBehavior,
            presentation: presentation
        )
    }

    @discardableResult
    func registerPendingToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool,
        requestedAt: Date = Date()
    ) async -> Bool {
        await stateStore.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            requestedAt: requestedAt,
            spec: approvalContractSpec(
                toolName: toolName,
                route: route,
                isElevated: isElevated
            )
        )
    }

    func toolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user
    ) async -> ToolApprovalResolution? {
        await stateStore.resolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
    }

    func waitForToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user
    ) async throws -> ToolApprovalResolution {
        try await stateStore.waitForResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
    }

    func resolveToolApprovalForAPI(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        durable: Bool = false
    ) async {
        if durable, status == .approved {
            await grantDurableToolRule(toolName: toolName)
        }
        await applyToolApprovalResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            kind: .manual,
            policyReason: "approvalRequired",
            publicationSource: "api.toolApproval"
        )
    }

    func consumeTimedOutToolApprovalsForRuntime(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int?,
        modelID: UUID?,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        let expired = await stateStore.consumeTimedOutApprovals()
        for entry in expired where entry.conversationID == conversationID && entry.runID == runID {
            await applyToolApprovalResolution(
                conversationID: entry.conversationID,
                runID: entry.runID,
                toolName: entry.toolName,
                route: entry.route,
                status: entry.status,
                source: entry.source,
                reason: entry.reason,
                kind: .timeoutDefault,
                policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                publicationSource: "runtime.approvalTimeout",
                iteration: iteration,
                modelID: modelID,
                approvalSpec: entry.spec,
                lifecycleEmitter: lifecycleEmitter
            )
        }
    }

    func applyToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        kind: ToolApprovalResolutionKind,
        policyReason: String,
        publicationSource: String,
        iteration: Int? = nil,
        modelID: UUID? = nil,
        approvalSpec: ToolApprovalContractSpec? = nil,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter? = nil
    ) async {
        await stateStore.setResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            kind: kind
        )
        await installedSubAgentSpawnService.applySubAgentTransportPermissionResolutionIfNeeded(
            conversationID: conversationID,
            toolName: toolName,
            route: route,
            status: status,
            source: source
        )
        let approvalState: RuntimeLifecycleApprovalState = switch status {
        case .approved: .approved
        case .denied: .denied
        case .pending: .pending
        }
        if let lifecycleEmitter {
            await lifecycleEmitter.emit(
                .toolApprovalResolved(
                    ToolApprovalResolvedInfo(
                        iteration: iteration,
                        modelID: modelID,
                        toolName: toolName,
                        toolCallID: nil,
                        approvalState: approvalState,
                        policyReason: policyReason,
                        approvalSource: source,
                        approvalReason: reason,
                        route: route,
                        title: approvalSpec?.title,
                        description: approvalSpec?.description,
                        severity: approvalSpec?.severity,
                        timeoutMs: approvalSpec?.timeoutMs,
                        timeoutBehavior: approvalSpec?.timeoutBehavior.rawValue,
                        resolutionKind: kind.rawValue,
                        presentation: approvalSpec?.presentation,
                        source: publicationSource
                    )
                ),
                conversationID: conversationID,
                runID: runID
            )
            return
        }
        let payload = RuntimeLifecycleEventPayload(
            name: .toolApprovalResolved,
            conversationID: conversationID,
            runID: runID,
            iteration: iteration,
            modelID: modelID,
            toolName: toolName,
            approvalState: approvalState,
            policyReason: policyReason,
            approvalSource: source,
            approvalReason: reason,
            approvalRoute: route,
            approvalTitle: approvalSpec?.title,
            approvalDescription: approvalSpec?.description,
            approvalSeverity: approvalSpec?.severity,
            approvalTimeoutMs: approvalSpec?.timeoutMs,
            approvalTimeoutBehavior: approvalSpec?.timeoutBehavior.rawValue,
            approvalResolutionKind: kind.rawValue,
            approvalPresentation: approvalSpec?.presentation,
            source: publicationSource
        )
        await topics.publishRuntimeLifecycleWithFanout(payload)
    }
}
