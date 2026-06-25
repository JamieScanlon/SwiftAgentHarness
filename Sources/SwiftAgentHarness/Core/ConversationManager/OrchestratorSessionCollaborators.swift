import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills

struct ModeTransitionContext: Sendable {
    let conversationID: UUID
    let fromProfile: ResolvedModeProfile
    let toProfile: ResolvedModeProfile
    let initiatedBy: String
    let reason: String?
}

protocol OrchestratorModePolicyProviding: Sendable {
    func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext
    func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile
    func defaultSessionModePolicyContext() async -> ModePolicyContext
    func systemPromptMetadata(for conversation: ModelConversation?, resolvedProfile: ResolvedModeProfile) async -> [String: String]
    func resolvedThinkingConfig(for conversation: ModelConversation, callContext: ThinkingCallContext) async -> ThinkingConfig
}

protocol OrchestratorSessionRuntimeCollaborating: Sendable {
    func startOrchestratorStateListeners(for conversationID: UUID) async
    func persistActivatedSkillsFromLoaderToCurrentConversation() async
    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async
    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline
    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async
}
