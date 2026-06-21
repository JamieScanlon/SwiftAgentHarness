import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills

protocol OrchestratorSessionPort: Sendable {
    func currentConversation() async -> ModelConversation?
    func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext
    func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile
    func systemPromptMetadata(for conversation: ModelConversation?, resolvedProfile: ResolvedModeProfile) async -> [String: String]
    func resolvedThinkingConfig(for conversation: ModelConversation, callContext: ThinkingCallContext) async -> ThinkingConfig
    func defaultSessionModePolicyContext() async -> ModePolicyContext
    func persistActivatedSkillsFromLoaderToCurrentConversation() async
    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline
    func recordContextSnapshot(from response: LLMResponse, requestConfig: LLMRequestConfig) async
    func startOrchestratorStateListeners(for conversationID: UUID) async
    func applySubagentCheckpointInvalidationIfNeeded(_ spec: ContextEngineSubagentCheckpointInvalidationSpec?) async
    func isHaltingToolCallForRuntime(toolName: String, effectiveEntries: [ToolRegistryEntry]) async -> Bool
    func setupOrchestrator(with model: Model, activeConversation: ModelConversation?) async
    func invalidateOrchestrator() async
    func generateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String
    func adoptPersistedNewConversationSelection(_ conversation: ModelConversation) async throws
    func runTransitionHookIDs(_ hookIDs: [String], context: ModeTransitionContext) async throws
    func rollbackMetadataTransition(
        conversationID: UUID,
        prior: ModelConversation,
        transitionContext: ModeTransitionContext,
        didPersistTransitionState: Bool,
        didRunExitHooks: Bool,
        didRunEnterHooks: Bool
    ) async
    func listSubAgentRegistryEntriesForAPI(conversationID: UUID) async throws -> [SubAgentRegistryEntry]
    func listSubAgentRegistryEntriesForAPI() async throws -> [SubAgentRegistryEntry]
    func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState?
}

/// Forwards ``OrchestratorSessionPort`` calls to ``OrchestratorSessionRuntimeService``.
final class OrchestratorSessionPortAdapter: OrchestratorSessionPort, Sendable {
    /// Use of @unchecked Sendable is valid here
    private final class Backing: @unchecked Sendable {
        var orchestratorService: OrchestratorSessionRuntimeService?
        var isInstalled = false

        func install(service: OrchestratorSessionRuntimeService) {
            precondition(!isInstalled, "OrchestratorSessionRuntimeService already installed")
            orchestratorService = service
            isInstalled = true
        }
    }

    private let backing: Backing

    var isInstalled: Bool { backing.isInstalled }

    init(service: OrchestratorSessionRuntimeService) {
        let backing = Backing()
        backing.orchestratorService = service
        backing.isInstalled = true
        self.backing = backing
    }

    static func makeUnbound() -> OrchestratorSessionPortAdapter {
        OrchestratorSessionPortAdapter(backing: Backing())
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func install(service: OrchestratorSessionRuntimeService) {
        backing.install(service: service)
    }

    func currentConversation() async -> ModelConversation? {
        guard let orchestratorService = backing.orchestratorService else { return nil }
        return await orchestratorService.currentConversation()
    }

    func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        guard let orchestratorService = backing.orchestratorService else {
            return ModePolicyContext(
                interactionMode: conversation.interactionMode,
                resolvedProfile: ResolvedModeProfile.builtIn(for: conversation.interactionMode)
            )
        }
        return await orchestratorService.modePolicyContext(for: conversation)
    }

    func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        guard let orchestratorService = backing.orchestratorService else { return ResolvedModeProfile.builtIn(for: conversation.interactionMode) }
        return await orchestratorService.resolvedModeProfile(for: conversation)
    }

    func systemPromptMetadata(
        for conversation: ModelConversation?,
        resolvedProfile: ResolvedModeProfile
    ) async -> [String: String] {
        guard let orchestratorService = backing.orchestratorService else { return [:] }
        return await orchestratorService.systemPromptMetadata(for: conversation, resolvedProfile: resolvedProfile)
    }

    func resolvedThinkingConfig(for conversation: ModelConversation, callContext: ThinkingCallContext) async -> ThinkingConfig {
        guard let orchestratorService = backing.orchestratorService else { return .disabled }
        return await orchestratorService.resolvedThinkingConfig(for: conversation, callContext: callContext)
    }

    func defaultSessionModePolicyContext() async -> ModePolicyContext {
        guard let orchestratorService = backing.orchestratorService else {
            return ModePolicyContext(interactionMode: .chat, resolvedProfile: ResolvedModeProfile.builtIn(for: .chat))
        }
        return await orchestratorService.defaultSessionModePolicyContext()
    }

    func persistActivatedSkillsFromLoaderToCurrentConversation() async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.persistActivatedSkillsFromLoaderToCurrentConversation()
    }

    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline {
        guard let orchestratorService = backing.orchestratorService else { return ToolResultMiddlewarePipeline(registrations: []) }
        return await orchestratorService.runtimeToolResultMiddlewarePipeline()
    }

    func recordContextSnapshot(from response: LLMResponse, requestConfig: LLMRequestConfig) async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.recordContextSnapshot(from: response, requestConfig: requestConfig)
    }

    func startOrchestratorStateListeners(for conversationID: UUID) async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.startOrchestratorStateListeners(for: conversationID)
    }

    func applySubagentCheckpointInvalidationIfNeeded(_ spec: ContextEngineSubagentCheckpointInvalidationSpec?) async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.applySubagentCheckpointInvalidationIfNeeded(spec)
    }

    func isHaltingToolCallForRuntime(toolName: String, effectiveEntries: [ToolRegistryEntry]) async -> Bool {
        guard let orchestratorService = backing.orchestratorService else { return false }
        return await orchestratorService.isHaltingToolCallForRuntime(toolName: toolName, effectiveEntries: effectiveEntries)
    }

    func setupOrchestrator(with model: Model, activeConversation: ModelConversation?) async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.setupOrchestrator(with: model, activeConversation: activeConversation)
    }

    func invalidateOrchestrator() async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.invalidateOrchestrator()
    }

    func generateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        guard let orchestratorService = backing.orchestratorService else { throw ConversationServiceError.failedToInitialize }
        return try await orchestratorService.generateFullSystemPrompt(
            conversationID: conversationID,
            withUserSystemPrompt: userSystemPrompt
        )
    }

    func adoptPersistedNewConversationSelection(_ conversation: ModelConversation) async throws {
        guard let orchestratorService = backing.orchestratorService else { throw ConversationServiceError.failedToInitialize }
        try await orchestratorService.adoptPersistedNewConversationSelection(conversation)
    }

    func runTransitionHookIDs(_ hookIDs: [String], context: ModeTransitionContext) async throws {
        guard let orchestratorService = backing.orchestratorService else { throw ConversationServiceError.failedToInitialize }
        try await orchestratorService.runTransitionHookIDs(hookIDs, context: context)
    }

    func rollbackMetadataTransition(
        conversationID: UUID,
        prior: ModelConversation,
        transitionContext: ModeTransitionContext,
        didPersistTransitionState: Bool,
        didRunExitHooks: Bool,
        didRunEnterHooks: Bool
    ) async {
        guard let orchestratorService = backing.orchestratorService else { return }
        await orchestratorService.rollbackMetadataTransition(
            conversationID: conversationID,
            prior: prior,
            transitionContext: transitionContext,
            didPersistTransitionState: didPersistTransitionState,
            didRunExitHooks: didRunExitHooks,
            didRunEnterHooks: didRunEnterHooks
        )
    }

    func listSubAgentRegistryEntriesForAPI(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        guard let orchestratorService = backing.orchestratorService else { throw ConversationServiceError.failedToInitialize }
        return try await orchestratorService.listSubAgentRegistryEntriesForAPI(conversationID: conversationID)
    }

    func listSubAgentRegistryEntriesForAPI() async throws -> [SubAgentRegistryEntry] {
        guard let orchestratorService = backing.orchestratorService else { throw ConversationServiceError.failedToInitialize }
        return try await orchestratorService.listSubAgentRegistryEntriesForAPI()
    }

    func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState? {
        guard let orchestratorService = backing.orchestratorService else { return nil }
        return await orchestratorService.snapshotOrchestrationState(for: conversationID)
    }
}
