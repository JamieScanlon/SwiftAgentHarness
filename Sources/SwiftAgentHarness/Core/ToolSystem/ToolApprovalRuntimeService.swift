import EasyJSON
import Foundation
import SwiftAgentKit

actor ToolApprovalRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let topics: ConversationTopicPublicationPort
    private let tenancyPolicy: TenancyPolicySettings
    nonisolated(unsafe) private var subAgentSpawnService: SubAgentSpawnService!
    private let stateStore = ToolApprovalStateStore()
    private let permissionRules: any PermissionRuleStore

    init(
        deps: ConversationRuntimeDependencies,
        topics: ConversationTopicPublicationPort,
        permissionRules: any PermissionRuleStore = InMemoryPermissionRuleStore(),
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.deps = deps
        self.topics = topics
        self.permissionRules = permissionRules
        self.tenancyPolicy = tenancyPolicy
    }

    private var strictTenancy: Bool {
        tenancyPolicy.requireAuthenticatedOwnerOnMutations
    }

    private func ownerAccountID(for conversationID: UUID) async -> UUID? {
        await deps.persistenceDomain.modelConversation(id: conversationID)?.ownerAccountID
    }

    /// Persists an `allow-always` rule for a tool so future runs (and restarts when
    /// the store is disk-backed) auto-approve it for the conversation owner.
    func grantDurableToolRule(
        toolName: String,
        conversationID: UUID,
        arguments: JSON? = nil
    ) async {
        let ownerAccountID = await ownerAccountID(for: conversationID)
        let rule: ToolPolicyRule
        if let arguments {
            rule = ToolPolicyDurableRuleFactory.ruleFromApprovedCall(toolName: toolName, arguments: arguments)
        } else {
            rule = .bareName(ToolNamePolicyNormalization.canonical(toolName))
        }
        await permissionRules.addToolRuleGrant(
            rule: rule,
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        )
        if rule.isNameLevelRule, let name = rule.canonicalToolName {
            await permissionRules.addToolGrant(
                toolName: name,
                ownerAccountID: ownerAccountID,
                strictTenancy: strictTenancy
            )
        }
    }

    /// Lists persisted durable tool-name grants for an owner, sorted ascending.
    func listDurableToolGrants(ownerAccountID: UUID?) async -> [String] {
        await permissionRules.grantedToolNames(
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        ).sorted()
    }

    /// Revokes a persisted durable tool-name grant for an owner.
    func revokeDurableToolGrant(toolName: String, ownerAccountID: UUID?) async {
        await permissionRules.removeToolGrant(
            toolName: toolName,
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        )
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
        out.preApprovedCallBindings.formUnion(
            await stateStore.approvedCallBindings(
                conversationID: conversationID,
                runID: runID,
                route: route
            )
        )
        out.preApprovedToolNames.formUnion(
            await stateStore.approvedToolNames(
                conversationID: conversationID,
                runID: runID,
                route: route
            )
        )
        let ownerAccountID = await ownerAccountID(for: conversationID)
        out.preApprovedToolNames.formUnion(
            await permissionRules.grantedToolNames(
                ownerAccountID: ownerAccountID,
                strictTenancy: strictTenancy
            )
        )
        out.preApprovedToolRules = await permissionRules.grantedToolRules(
            ownerAccountID: ownerAccountID,
            strictTenancy: strictTenancy
        )
        return out
    }

    nonisolated func approvalContractSpec(
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool,
        arguments: JSON? = nil
    ) -> ToolApprovalContractSpec {
        let severity = isElevated
            ? deps.toolPolicy.approvalElevatedSeverityDefault
            : deps.toolPolicy.approvalSeverityDefault
        let title = isElevated ? "Elevated Tool Approval Required" : "Tool Approval Required"
        var description = "Approve \(toolName) for this call (route: \(route.rawValue))."
        var contextLines = [
            "Tool: \(toolName)",
            "Route: \(route.rawValue)  Severity: \(severity)",
            isElevated ? "This tool runs with elevated privileges." : "",
        ]
        if let arguments {
            let binding = ToolCallApprovalBinding.from(toolName: toolName, arguments: arguments)
            description += " Arguments fingerprint: \(binding.argumentsFingerprint.prefix(12))…"
            contextLines.append("Arguments: \(Self.argumentsSummary(arguments))")
        }
        let presentation = ApprovalPresentation.standard(
            title: title,
            context: contextLines
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
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute,
        isElevated: Bool,
        requestedAt: Date = Date()
    ) async -> Bool {
        await stateStore.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route,
            requestedAt: requestedAt,
            spec: approvalContractSpec(
                toolName: binding.toolName,
                route: route,
                isElevated: isElevated,
                arguments: nil
            )
        )
    }

    func registerPendingToolApproval(
        conversationID: UUID,
        runID: UUID?,
        call: ToolCallRequest,
        route: ToolApprovalRoute,
        isElevated: Bool,
        requestedAt: Date = Date()
    ) async -> Bool {
        let binding = ToolCallApprovalBinding.from(call: call)
        return await stateStore.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route,
            requestedAt: requestedAt,
            spec: approvalContractSpec(
                toolName: binding.toolName,
                route: route,
                isElevated: isElevated,
                arguments: call.arguments
            )
        )
    }

    func toolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user
    ) async -> ToolApprovalResolution? {
        await stateStore.resolution(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route
        )
    }

    func waitForToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user
    ) async throws -> ToolApprovalResolution {
        try await stateStore.waitForResolution(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
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
        durable: Bool = false,
        arguments: JSON? = nil
    ) async throws {
        let binding = try await stateStore.resolveBindingForAPI(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            arguments: arguments
        )
        let decision: ApprovalDecision? = switch status {
        case .approved:
            durable ? .allowAlways : .allowOnce
        case .denied, .pending:
            .deny
        }
        if durable, status == .approved {
            await grantDurableToolRule(
                toolName: toolName,
                conversationID: conversationID,
                arguments: arguments
            )
        }
        await applyToolApprovalResolution(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route,
            status: status,
            source: source,
            reason: reason,
            kind: .manual,
            decision: decision,
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
        let expired = await stateStore.consumeTimedOutApprovals(
            conversationID: conversationID,
            runID: runID
        )
        for entry in expired {
            await applyToolApprovalResolution(
                conversationID: entry.conversationID,
                runID: entry.runID,
                binding: entry.binding,
                route: entry.route,
                status: entry.status,
                source: entry.source,
                reason: entry.reason,
                kind: .timeoutDefault,
                decision: entry.status == .approved ? .allowOnce : .deny,
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
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        kind: ToolApprovalResolutionKind,
        decision: ApprovalDecision? = nil,
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
            binding: binding,
            route: route,
            status: status,
            source: source,
            reason: reason,
            kind: kind,
            decision: decision
        )
        await installedSubAgentSpawnService.applySubAgentTransportPermissionResolutionIfNeeded(
            conversationID: conversationID,
            toolName: binding.toolName,
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
                        toolName: binding.toolName,
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
            toolName: binding.toolName,
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

    private nonisolated static func argumentsSummary(_ arguments: JSON) -> String {
        switch arguments {
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let pairs = fields.keys.sorted().prefix(4).compactMap { key -> String? in
                guard let value = fields[key] else { return nil }
                return "\(key)=\(Self.jsonScalarSummary(value))"
            }
            let suffix = fields.count > 4 ? ", …" : ""
            return "{\(pairs.joined(separator: ", "))\(suffix)}"
        default:
            return Self.jsonScalarSummary(arguments)
        }
    }

    private nonisolated static func jsonScalarSummary(_ json: JSON) -> String {
        switch json {
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 48 { return trimmed }
            return String(trimmed.prefix(45)) + "…"
        case .array(let values): return "[\(values.count) items]"
        case .object(let fields): return "{\(fields.count) keys}"
        }
    }
}
