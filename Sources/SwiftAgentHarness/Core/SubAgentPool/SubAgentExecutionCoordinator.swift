import Foundation
import EasyJSON

struct SubAgentPreparedLaunch: Sendable {
    var launchRequest: SubAgentLaunchRequest
    var launchPlan: SubAgentLaunchPlan
    var parentDepth: Int
    var selectedRegistryEntry: SubAgentRegistryEntry?
    var selectedToolEntry: ToolRegistryEntry?
}

struct SubAgentExecutionCoordinator: Sendable {
    private let subAgentPool: any SubAgentPooling

    init(subAgentPool: any SubAgentPooling) {
        self.subAgentPool = subAgentPool
    }

    func prepareLaunch(
        parentConversationID: UUID,
        parentConversation: ModelConversation,
        request: SubAgentSpawnRequest,
        orchestrationEntries: [ToolRegistryEntry],
        modeSubAgentAllowList: [String]?,
        modeProfileMaxDepth: Int?,
        parentDepth: Int
    ) async throws -> SubAgentPreparedLaunch {
        var launchRequest = subAgentPool.normalizeLaunchRequest(request)
        if launchRequest.routingContext.hostPersonaID == nil {
            launchRequest.routingContext.hostPersonaID = metadataString(parentConversation.metadata, key: "subAgentHostPersonaID")
        }
        if launchRequest.routingContext.routingDomain == nil {
            launchRequest.routingContext.routingDomain = metadataString(parentConversation.metadata, key: "subAgentRoutingDomain")
        }
        if launchRequest.routingContext.tenantScope == nil {
            launchRequest.routingContext.tenantScope = metadataString(parentConversation.metadata, key: "subAgentTenantScope")
        }
        if launchRequest.routingContext.authScopeTags.isEmpty {
            launchRequest.routingContext.authScopeTags = metadataStringArray(parentConversation.metadata, key: "subAgentAuthScopeTags")
        }

        launchRequest = try await subAgentPool.resolveSubAgent(
            launchRequest,
            from: orchestrationEntries,
            conversationID: parentConversationID
        )
        let selectedTransportAdapter = await subAgentPool.selectTransportAdapter(
            for: launchRequest,
            entries: orchestrationEntries,
            conversationID: parentConversationID
        )
        if let adapter = selectedTransportAdapter, launchRequest.subagentType == nil {
            launchRequest.subagentType = adapter.transportKind.rawValue
        }

        let registryEntries = await subAgentPool.listSubAgents(
            from: orchestrationEntries,
            routingContext: nil,
            conversationID: parentConversationID
        )
        let selectedRegistryEntry = launchRequest.agentID.flatMap { agentID in
            registryEntries.first {
                $0.agentID.caseInsensitiveCompare(agentID) == .orderedSame
                    || $0.delegateToolName.caseInsensitiveCompare(agentID) == .orderedSame
            }
        }
        let selectedToolEntry = launchRequest.agentID.flatMap { agentID in
            orchestrationEntries.first {
                $0.name.caseInsensitiveCompare(agentID) == .orderedSame
            }
        }

        var depthCaps: [Int] = []
        if let registryCap = selectedRegistryEntry?.maxRecursionDepth {
            depthCaps.append(registryCap)
        }
        if let profileCap = modeProfileMaxDepth {
            depthCaps.append(profileCap)
        }
        if let transportCap = selectedTransportAdapter?.capabilities.maxRecursionDepth {
            depthCaps.append(transportCap)
        } else if let selectedToolEntry,
                  let toolCap = subAgentPool.maxRecursionDepth(for: selectedToolEntry) {
            depthCaps.append(toolCap)
        }
        let effectiveMaxDepth = depthCaps.min() ?? SubAgentRecursionLimits.absoluteMaxDepthFallback
        if parentDepth >= effectiveMaxDepth {
            throw ConversationServiceError.runtimeLaneUnavailable(
                reason: "subagent_recursion_depth_exceeded:\(effectiveMaxDepth)"
            )
        }

        let launchPlan = try subAgentPool.planLaunch(launchRequest, parentConversationID: parentConversationID)
        let delegateToolName = launchPlan.delegationContext.delegateToolName
            ?? selectedRegistryEntry?.delegateToolName
            ?? selectedToolEntry?.name
        guard modeSubAgentAllowListAllows(modeSubAgentAllowList, delegateToolName: delegateToolName) else {
            throw ConversationServiceError.runtimeLaneUnavailable(reason: "subagent_delegate_not_allowed_by_mode_profile")
        }

        return SubAgentPreparedLaunch(
            launchRequest: launchRequest,
            launchPlan: launchPlan,
            parentDepth: parentDepth,
            selectedRegistryEntry: selectedRegistryEntry,
            selectedToolEntry: selectedToolEntry
        )
    }

    private func modeSubAgentAllowListAllows(_ modeAllowList: [String]?, delegateToolName: String?) -> Bool {
        guard let modeAllowList else { return true }
        let normalized = Set(modeAllowList.map { $0.lowercased() })
        if normalized.contains("*") {
            return true
        }
        guard let delegateToolName else {
            return false
        }
        return normalized.contains(delegateToolName.lowercased())
    }

    private func metadataString(_ metadata: JSON?, key: String) -> String? {
        guard let metadata, case .object(let object) = metadata else { return nil }
        return object[key]?.literalValue as? String
    }

    private func metadataStringArray(_ metadata: JSON?, key: String) -> [String] {
        guard let metadata, case .object(let object) = metadata else { return [] }
        guard let array = object[key]?.literalValue as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }
}
