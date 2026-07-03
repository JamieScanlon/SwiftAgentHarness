import EasyJSON
import Foundation
import SwiftAgentKit

/// Tool-provider data seam (catalog, selection, send, mode metadata) without session owning protocols.
actor ConversationToolDataService {
    private let catalog: any ConversationCatalogServicing
    private let controlPlane: any ConversationControlPlaneServicing
    private let agentRuntime: any AgentRuntimeStreamingServicing
    private let selection: ConversationSelectionAccessing
    private let tenancyPolicy: TenancyPolicySettings

    init(
        catalog: any ConversationCatalogServicing,
        controlPlane: any ConversationControlPlaneServicing,
        agentRuntime: any AgentRuntimeStreamingServicing,
        selection: ConversationSelectionAccessing,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.catalog = catalog
        self.controlPlane = controlPlane
        self.agentRuntime = agentRuntime
        self.selection = selection
        self.tenancyPolicy = tenancyPolicy
    }

    func serviceListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        let rows = await catalog.listConversationMetadata(visibility: visibility)
        let context = await callerAccessContext()
        return ToolConversationAccessPolicy.filterAccessibleMetadata(
            rows,
            callerScope: context.scope,
            ownerScope: context.ownerScope,
            callerLineageRoot: context.callerLineageRoot,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        )
    }

    func serviceGetConversation(id: UUID) async -> ModelConversation? {
        guard let conversation = await unscopedConversation(id: id) else {
            return nil
        }
        guard await isToolAccessible(conversation) else {
            return nil
        }
        return conversation
    }

    func selectConversation(conversationID: UUID) async throws {
        _ = try await assertToolAccessible(conversationID: conversationID)
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
        _ = try await assertToolAccessible(conversationID: conversationID)
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

    private struct CallerAccessContext: Sendable {
        let scope: ConversationScope?
        let ownerScope: UUID?
        let callerLineageRoot: UUID?
    }

    private func unscopedConversation(id: UUID) async -> ModelConversation? {
        await catalog.getConversation(id: id)
    }

    private func callerAccessContext() async -> CallerAccessContext {
        let scope = ConversationScope.current
        let callerConversation: ModelConversation?
        if let callerID = scope?.selfID {
            callerConversation = await unscopedConversation(id: callerID)
        } else {
            callerConversation = nil
        }
        let ownerScope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations,
            authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
            callerConversation: callerConversation,
            registryOwnerAccountID: await catalog.registryOwnerAccountID()
        )
        let callerLineageRoot: UUID?
        if let callerConversation {
            callerLineageRoot = await lineageRoot(for: callerConversation)
        } else {
            callerLineageRoot = nil
        }
        return CallerAccessContext(
            scope: scope,
            ownerScope: ownerScope,
            callerLineageRoot: callerLineageRoot
        )
    }

    private func lineageRoot(for conversation: ModelConversation) async -> UUID {
        await ToolConversationAccessPolicy.lineageRoot(for: conversation) { id in
            await self.unscopedConversation(id: id)
        }
    }

    private func isToolAccessible(_ target: ModelConversation) async -> Bool {
        let context = await callerAccessContext()
        let targetLineageRoot = await lineageRoot(for: target)
        return ToolConversationAccessPolicy.isConversationAccessible(
            target: target,
            callerScope: context.scope,
            ownerScope: context.ownerScope,
            callerLineageRoot: context.callerLineageRoot,
            targetLineageRoot: targetLineageRoot,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        )
    }

    private func assertToolAccessible(conversationID: UUID) async throws -> ModelConversation {
        guard let conversation = await unscopedConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard await isToolAccessible(conversation) else {
            throw ConversationServiceError.conversationNotFound
        }
        return conversation
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
        _ = try await assertToolAccessible(conversationID: conversationID)
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
