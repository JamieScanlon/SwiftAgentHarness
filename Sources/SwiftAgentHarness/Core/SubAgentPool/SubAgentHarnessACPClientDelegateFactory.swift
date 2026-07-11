import Foundation
import SwiftAgentKit
import SwiftAgentKitACP
import SwiftAgentKitOrchestrator

struct SubAgentHarnessACPClientDelegateFactory: SubAgentACPClientDelegateMaking {
    let deps: ConversationRuntimeDependencies
    let gateway: any ToolSystemGatewaying
    let subAgentPool: any SubAgentPooling
    let toolApproval: any ToolApprovalRuntimeServicing
    let resolveChannelRegistry: @Sendable () -> (any ChannelPluginLooking)?
    let resolveOrchestrator: @Sendable () async -> SwiftAgentKitOrchestrator?
    let resolveToolEntries: @Sendable () async -> [ToolRegistryEntry]
    let resolveModePolicyContext: @Sendable (ModelConversation) async -> ModePolicyContext

    func makeDelegate(
        request: SubAgentTransportInvocationRequest,
        lifecycleID: String
    ) async -> any ACPClientDelegate {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: request.parentConversationID) else {
            return DefaultACPClientDelegate(autoApprovePermissions: false)
        }
        let workspaceRoot = conversation.harnessPersistenceCwd ?? FileManager.default.currentDirectoryPath
        let memoryService = (deps.contextEngine as? DefaultContextEngine)?.memoryService
        var memoryDirectory: URL?
        if let memoryService,
           let context = try? memoryService.makeSessionContext(
            conversationID: conversation.id,
            cwd: workspaceRoot
           ) {
            memoryDirectory = context.memoryDirectory
        }
        let sessionKey = conversation.id.uuidString
        let approvalDelivery = await ExecApprovalDeliveryFactory.make(
            scope: ExecApprovalScope(
                conversationID: conversation.id,
                ownerAccountID: conversation.ownerAccountID
            ),
            channelRegistry: resolveChannelRegistry(),
            metadata: conversation.metadata
        )
        let execRuntime = ExecRuntimeService(
            workspaceRoot: workspaceRoot,
            approvalDelivery: approvalDelivery,
            logger: deps.logger
        )
        let skillsDirectory = (try? SystemPrompt.loadSkillsFolderPathFromConfig())
            .flatMap { SkillsDirectoryResolver.resolve(workspaceRoot: workspaceRoot, configuredPath: $0) }
        let runtimeContext = ExecRuntimeContext(
            sessionKey: sessionKey,
            agentID: sessionKey,
            isMainSession: true,
            memoryDirectory: memoryDirectory?.path,
            skillsDirectory: skillsDirectory?.path,
            memoryWriteOnly: ConversationLineageInference.isMemoryWriteScopedProfile(conversation.modeProfileID)
        )
        let baseConfiguration = HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
        let policyConfiguration = await toolApproval.configurationApplyingToolApprovals(
            baseConfiguration,
            conversationID: conversation.id,
            runID: conversation.currentRunID
        )
        var runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: policyConfiguration)
        runtimeConfiguration.inputTrustRaw = SubAgentTrustLevel.unknownParty.rawValue
        let modePolicyContext = await resolveModePolicyContext(conversation)
        let toolEntries = await resolveToolEntries()
        let dispatchContext = SubAgentACPToolDispatchContext(
            conversation: conversation,
            workspaceRoot: workspaceRoot,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            gateway: gateway,
            toolPolicy: deps.toolPolicy,
            trustPolicy: deps.trustPolicyConfiguration,
            modePolicyContext: modePolicyContext,
            runtimeConfiguration: runtimeConfiguration,
            subAgentPool: subAgentPool,
            toolEntries: toolEntries,
            permissionPolicy: request.registryEntry.permissionPolicy,
            permissionAlreadyGranted: SubAgentTransportPermissionGate.permissionAlreadyGranted(request),
            delegateToolName: request.registryEntry.delegateToolName
        )
        return HarnessACPClientDelegate(
            context: dispatchContext,
            executor: LocalSandboxBashExecutor(execRuntime: execRuntime, runtimeContext: runtimeContext),
            lifecycleID: lifecycleID
        )
    }
}
