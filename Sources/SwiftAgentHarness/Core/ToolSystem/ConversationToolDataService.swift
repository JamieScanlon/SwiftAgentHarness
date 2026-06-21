import EasyJSON
import Foundation
import SwiftAgentKit

/// Tool-provider data seam (catalog, selection, send, mode metadata) without session owning protocols.
actor ConversationToolDataService {
    private let catalog: any ConversationCatalogServicing
    private let controlPlane: any ConversationControlPlaneServicing
    private let agentRuntime: any AgentRuntimeStreamingServicing
    private let selection: ConversationSelectionAccessing

    init(
        catalog: any ConversationCatalogServicing,
        controlPlane: any ConversationControlPlaneServicing,
        agentRuntime: any AgentRuntimeStreamingServicing,
        selection: ConversationSelectionAccessing
    ) {
        self.catalog = catalog
        self.controlPlane = controlPlane
        self.agentRuntime = agentRuntime
        self.selection = selection
    }

    func serviceListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        await catalog.listConversationMetadata(visibility: visibility)
    }

    func serviceGetConversation(id: UUID) async -> ModelConversation? {
        await catalog.getConversation(id: id)
    }

    func selectConversation(conversationID: UUID) async throws {
        try await selection.selectConversation(conversationID: conversationID)
    }

    func serviceSendMessageAndStreamResponseForSwitch(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        try await agentRuntime.serviceRuntimeSendMessageAndStreamResponse(
            text,
            images: images,
            conversationID: conversationID,
            configuration: configuration
        )
    }

    func updateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode?,
        modeProfileID: String?,
        interactionModeChangeInitiator: String?,
        interactionModeChangeReason: String?,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        try await controlPlane.updateConversationMetadata(
            conversationID: conversationID,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            interactionModeChangeInitiator: interactionModeChangeInitiator,
            interactionModeChangeReason: interactionModeChangeReason,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }
}

extension ConversationToolDataService: ConversationsDataProviding {
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        await serviceListConversationMetadata(visibility: visibility)
    }

    func getConversation(id: UUID) async -> ModelConversation? {
        await serviceGetConversation(id: id)
    }

    func switchConversation(id: UUID, message: String?) async throws -> String? {
        try await selectConversation(conversationID: id)
        guard let message, !message.isEmpty else { return nil }
        let stream = try await serviceSendMessageAndStreamResponseForSwitch(
            message,
            images: [],
            conversationID: id,
            configuration: .init(
                enableTools: true,
                enableAgents: true,
                expectedPreviousTailHarnessMessageID: nil,
                inputTrustRaw: nil
            )
        )
        Task {
            for await _ in stream.partialContent {}
        }
        return nil
    }
}

extension ConversationToolDataService: ModeTransitionDataProviding {
    func transitionConversationMode(
        conversationID: UUID,
        targetMode: InteractionMode,
        initiatedBy: String,
        reason: String?
    ) async throws -> ModeTransitionApplyResult {
        guard initiatedBy == "tool", let reason else {
            try await updateConversationMetadata(
                conversationID: conversationID,
                topic: nil,
                description: nil,
                metadata: nil,
                interactionMode: targetMode,
                modeProfileID: targetMode.rawValue,
                interactionModeChangeInitiator: initiatedBy,
                interactionModeChangeReason: reason,
                skipControlPlaneRevisionBump: false
            )
            return .applied
        }
        return try await controlPlane.scheduleOrApplyToolModeTransition(
            conversationID: conversationID,
            targetMode: targetMode,
            modeProfileID: targetMode.rawValue,
            reason: reason
        )
    }
}

struct ContextCompactionProjectionPerformer: ContextCompactionPerforming {
    let projection: ContextProjectionService

    func performManualCompaction(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        reason: String?
    ) async throws -> ContextCompactionManualResult {
        try await projection.performManualCompaction(
            conversationID: conversationID,
            trigger: trigger,
            reason: reason
        )
    }
}
