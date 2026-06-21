import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension ToolApprovalRuntimeService: ToolApprovalRuntimeServicing {}

extension OrchestratorRuntimeService: OrchestratorRuntimeToolPolicyServicing, SubAgentOrchestratorRuntimeServicing {}

extension ContextProjectionService: ContextProjectionTransformServicing {
    func transformedContextMessages(
        from originalMessages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        configuration: HarnessRuntimeSession.Configuration,
        gatingOverride: ContextCompactionGatingOptions?
    ) async -> [Message] {
        let harnessConfiguration: HarnessRuntimeSession.Configuration? = configuration
        return await transformedContextMessages(
            from: originalMessages,
            conversation: conversation,
            phase: phase,
            configuration: harnessConfiguration,
            gatingOverride: gatingOverride
        )
    }
}

extension SlashCommandDispatchService: SlashCommandRuntimeDispatching {
    func runSlashCommandIfNeeded(_ text: String, conversationID: UUID) async throws -> ChatStreamResponse? {
        try await runSlashCommandIfNeeded(text, conversationID: conversationID, skipQueue: false)
    }
}

extension ConversationToolDataService: ConversationToolDataProviding {
    func conversationToolData() async -> ConversationToolDataService { self }
}

extension SubAgentSpawnService: SubAgentSpawnDelegating, SubAgentSpawnLifecycleServicing {}
