import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitSkills

/// API tool/mode/skill policy reads without `HarnessRuntimeSession` owning conformance.
actor ConversationToolModePolicyRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let orchestratorRuntime: OrchestratorRuntimeService
    private let agentRuntime: any AgentRuntimeOrchestratorBinding
    private let skillActivation: SkillActivationService
    private let slashCommandDispatch: SlashCommandDispatchService
    private let toolApproval: ToolApprovalRuntimeService
    private let subAgentPool: any SubAgentPooling
    nonisolated(unsafe) private var toolData: ConversationToolDataService!
    private let selection: ConversationSelectionAccessing
    private let toolSystemGateway: any ToolSystemGatewaying

    init(
        deps: ConversationRuntimeDependencies,
        orchestratorRuntime: OrchestratorRuntimeService,
        agentRuntime: any AgentRuntimeOrchestratorBinding,
        skillActivation: SkillActivationService,
        slashCommandDispatch: SlashCommandDispatchService,
        toolApproval: ToolApprovalRuntimeService,
        subAgentPool: any SubAgentPooling,
        selection: ConversationSelectionAccessing
    ) {
        self.deps = deps
        self.orchestratorRuntime = orchestratorRuntime
        self.agentRuntime = agentRuntime
        self.skillActivation = skillActivation
        self.slashCommandDispatch = slashCommandDispatch
        self.toolApproval = toolApproval
        self.subAgentPool = subAgentPool
        self.selection = selection
        self.toolSystemGateway = DefaultToolSystemGateway(visibilityGrants: deps.visibilityGrants)
    }

    nonisolated func installToolData(_ toolData: ConversationToolDataService) {
        precondition(self.toolData == nil, "ConversationToolDataService already installed")
        self.toolData = toolData
    }

    private var installedToolData: ConversationToolDataService {
        guard let toolData else {
            preconditionFailure("ConversationToolDataService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return toolData
    }


    private var modeRegistry: any ModeRegistryAccessing { deps.modeRegistry }
    private var toolPolicy: ToolPolicyConfiguration { deps.toolPolicy }
    private var trustPolicy: TrustPolicyConfiguration { deps.trustPolicyConfiguration }
    private var logger: Logger? { deps.logger }

    private func turnConfigurationForAPIListing(
        conversationID: UUID,
        conversation: ModelConversation
    ) async -> AgentRuntimeTurnConfiguration {
        let policyConfiguration = await toolApproval.configurationApplyingToolApprovals(
            HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true),
            conversationID: conversationID,
            runID: conversation.currentRunID
        )
        return AgentRuntimeTurnConfiguration(managerConfiguration: policyConfiguration)
    }

    private func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        (await modeRegistry.resolveReportingFallback(
            modeId: conversation.modeProfileID ?? conversation.interactionMode.rawValue,
            logger: logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile
    }

    private func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        ModePolicyContext(conversation: conversation, resolvedProfile: await resolvedModeProfile(for: conversation))
    }

    private func defaultSessionModePolicyContext() async -> ModePolicyContext {
        let resolved = try! await modeRegistry.resolve(modeId: InteractionMode.chat.rawValue)
        return ModePolicyContext(interactionMode: .chat, resolvedProfile: resolved)
    }

    func apiRegistryEntriesForListing(preferredConversation: ModelConversation?) async -> [ToolRegistryEntry] {
        let conversation: ModelConversation?
        if let preferredConversation {
            conversation = preferredConversation
        } else {
            conversation = await selection.currentConversation()
        }
        guard let conversation else { return [] }
        let orchestrator = await orchestratorRuntime.buildTransientOrchestratorForCatalog(
            model: conversation.model,
            conversation: conversation
        )
        // Do not call orchestrator.shutdown() — managers are session-owned / shared.
        if let orchestrator {
            return await OrchestrationToolCatalog.registryEntriesForListing(
                orchestrator: orchestrator,
                dataProvider: installedToolData,
                logger: logger,
                executionEnvironmentAdapter: SandboxToolExecutionEnvironmentAdapter()
            )
        }
        return []
    }
}

extension ConversationToolModePolicyRuntimeService: ConversationToolModePolicyOwning {
    func listAvailableToolsForAPI(conversationID: UUID) async throws -> [AvailableToolInfo] {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let entries = await apiRegistryEntriesForListing(preferredConversation: conversation)
        let configuration = await turnConfigurationForAPIListing(
            conversationID: conversationID,
            conversation: conversation
        )
        return toolSystemGateway.availableToolsForAPI(
            entries: entries,
            conversation: conversation,
            modePolicyContext: await modePolicyContext(for: conversation),
            configuration: configuration,
            toolPolicy: toolPolicy,
            trustPolicy: trustPolicy,
            subAgentToolClassifier: subAgentPool
        )
    }

    func listAvailableToolsForAPI() async throws -> [AvailableToolInfo] {
        let entries = await apiRegistryEntriesForListing(preferredConversation: nil)
        return OrchestrationToolCatalog.availableToolInfos(from: entries)
    }

    func listAvailableSkillsForAPI(conversationID: UUID) async throws -> [AvailableSkillInfo] {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard deps.configurationSet.promptAssembly.includeAgentSkills else { return [] }
        guard let skillLoader = await skillActivation.skillLoader(for: conversationID) else { return [] }
        let all = try await skillLoader.loadMetadata()
        let policyCtx = await modePolicyContext(for: conversation)
        let eligible = all.filter {
            policyCtx.resolvedProfile.skills.isSkillAllowed(name: $0.name, context: policyCtx)
                && ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(
                    name: $0.name,
                    conversation: conversation
                )
        }
        return eligible.map { AvailableSkillInfo(name: $0.name, description: $0.description) }
    }

    func listAvailableSkillsForAPI() async throws -> [AvailableSkillInfo] {
        guard deps.configurationSet.promptAssembly.includeAgentSkills else { return [] }
        guard let skillLoader = await skillActivation.skillLoader(for: nil) else { return [] }
        let all = try await skillLoader.loadMetadata()
        let policyCtx = await defaultSessionModePolicyContext()
        let eligible = all.filter {
            policyCtx.resolvedProfile.skills.isSkillAllowed(name: $0.name, context: policyCtx)
        }
        return eligible.map { AvailableSkillInfo(name: $0.name, description: $0.description) }
    }

    func listModeProfilesForAPI() async throws -> [ModeProfilePickerRow] {
        await modeRegistry.profilesForPicker()
    }

    func reloadModeProfilesForAPI() async throws -> Bool {
        await modeRegistry.reloadProjectConfig()
    }

    func listSlashCommandsForAPI(conversationID: UUID) async throws -> [SlashCommandAutocompleteEntry] {
        try await slashCommandDispatch.listSlashCommandsForAPI(conversationID: conversationID)
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
        try await toolApproval.resolveToolApprovalForAPI(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            durable: durable,
            arguments: arguments
        )
    }
}
