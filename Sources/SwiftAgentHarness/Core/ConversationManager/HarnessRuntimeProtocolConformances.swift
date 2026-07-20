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

    func cachedProjectedMemorySelectionKeys(conversationID: UUID) async -> Set<String> {
        projectedMemorySelectionKeysSnapshot(conversationID: conversationID)
    }
}

extension SlashCommandDispatchService: SlashCommandRuntimeDispatching {
    func runSlashCommandIfNeeded(_ text: String, conversationID: UUID) async throws -> ChatStreamResponse? {
        let isOwner = await resolvedSlashDispatchIsOwner(conversationID: conversationID)
        return try await runSlashCommandIfNeeded(
            text,
            conversationID: conversationID,
            skipQueue: false,
            isOwner: isOwner
        )
    }

    func processControlInputBoundary(
        text: String,
        conversationID: UUID,
        trustClass: TrustPolicyClass?,
        senderLabel: String?
    ) async throws -> ControlInputBoundaryOutcome {
        try await processControlInputBoundary(
            text: text,
            conversationID: conversationID,
            trustClass: trustClass,
            senderLabel: senderLabel,
            capabilities: .terminal
        )
    }
}

extension ConversationToolDataService: ConversationToolDataProviding {
    func conversationToolData() async -> ConversationToolDataService { self }
}

extension SubAgentSpawnService: SubAgentSpawnDelegating, SubAgentSpawnLifecycleServicing {}
