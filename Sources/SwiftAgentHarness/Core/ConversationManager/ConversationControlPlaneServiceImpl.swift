import EasyJSON
import Foundation
import SwiftAgentKit

actor ConversationControlPlaneServiceImpl: ConversationControlPlaneServicing {
    private struct PendingModeTransitionKey: Hashable, Sendable {
        let conversationID: UUID
        let runID: UUID
    }

    private struct PendingModeTransition: Sendable {
        let topic: String?
        let description: String?
        let metadata: JSON?
        let interactionMode: InteractionMode?
        let modeProfileID: String?
        let initiator: String
        let reason: String?
        let skipControlPlaneRevisionBump: Bool
    }

    private let deps: ConversationRuntimeDependencies
    private let orchestrationCore: AgentRuntimeOrchestrationCore
    nonisolated(unsafe) private var runControl: (any AgentRuntimeRunControlling)!
    private let orchestratorRuntime: OrchestratorRuntimeService
    private let selection: ConversationSelectionAccessing
    private let orchestrator: OrchestratorSessionPort
    private let topics: ConversationTopicPublicationPort
    private let messaging: ConversationMessagingPort
    private let sessionProjection: SessionProjectionAccessing
    private var pendingModeTransitions: [PendingModeTransitionKey: PendingModeTransition] = [:]

    init(
        deps: ConversationRuntimeDependencies,
        orchestrationCore: AgentRuntimeOrchestrationCore,
        orchestratorRuntime: OrchestratorRuntimeService,
        selection: ConversationSelectionAccessing,
        orchestrator: OrchestratorSessionPort,
        topics: ConversationTopicPublicationPort,
        messaging: ConversationMessagingPort,
        sessionProjection: SessionProjectionAccessing
    ) {
        self.deps = deps
        self.orchestrationCore = orchestrationCore
        self.orchestratorRuntime = orchestratorRuntime
        self.selection = selection
        self.orchestrator = orchestrator
        self.topics = topics
        self.messaging = messaging
        self.sessionProjection = sessionProjection
    }

    nonisolated func installRunControl(_ runControl: any AgentRuntimeRunControlling) {
        precondition(self.runControl == nil, "AgentRuntimeRunControlling already installed")
        self.runControl = runControl
    }

    private var installedRunControl: any AgentRuntimeRunControlling {
        guard let runControl else {
            preconditionFailure("AgentRuntimeRunControlling not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return runControl
    }


    func patchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        try await applyConversationPatch(conversationID: conversationID, patch: patch, skipControlPlaneRevisionBump: false)
    }

    func applyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        guard let current = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        if patch.expectedRevision != current.controlPlaneRevision {
            throw ConversationServiceError.conversationRevisionMismatch(
                conversationID: conversationID,
                expectedRevision: patch.expectedRevision,
                currentRevision: current.controlPlaneRevision
            )
        }
        if resolvedModel != nil || patch.userSystemPrompt != nil {
            try await updateConversationModelAndUserPrompt(
                conversationID: conversationID,
                model: resolvedModel,
                userSystemPrompt: patch.userSystemPrompt,
                skipControlPlaneRevisionBump: true
            )
        }
        var remainder = patch
        remainder.modelRef = nil
        remainder.userSystemPrompt = nil
        try await applyConversationPatch(conversationID: conversationID, patch: remainder, skipControlPlaneRevisionBump: true)
        try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
        guard let updated = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return updated.controlPlaneRevision
    }

    func composeModelReferenceForRouting(
        conversationID: UUID?,
        interactionMode: InteractionMode?,
        clientReference: ModelReference
    ) async -> ModelReference {
        let routingQueryJSON: String?
        let resolved: ResolvedModeProfile
        if let conversationID,
           let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) {
            routingQueryJSON = conversation.routingPrefs?.queryJSON
            resolved = await resolvedModeProfile(for: conversation)
        } else if let interactionMode {
            routingQueryJSON = nil
            resolved = (await deps.modeRegistry.resolveReportingFallback(
                modeId: interactionMode.rawValue,
                logger: deps.logger,
                fallbackModeId: InteractionMode.chat.rawValue
            )).profile
        } else {
            return clientReference
        }
        return ModeProfileModelRouting.effectiveModelReference(
            clientReference,
            routingQueryJSON: routingQueryJSON,
            resolvedProfile: resolved
        )
    }

    func generateFullSystemPrompt(conversationID: UUID?, userSystemPrompt: String?) async throws -> String {
        do {
            return try await orchestrator.generateFullSystemPrompt(
                conversationID: conversationID,
                withUserSystemPrompt: userSystemPrompt
            )
        } catch ConversationServiceError.failedToInitialize {
            throw ConversationServiceError.conversationNotFound
        }
    }

    func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        cwd: String? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) async throws -> UUID {
        let effectiveInteractionMode = await resolvedInteractionModeForModeProfile(
            modeProfileID: modeProfileID,
            fallbackInteractionMode: interactionMode
        ) ?? interactionMode
        let newConversation = try await deps.persistenceDomain.createConversation(
            with: selectedModel,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: effectiveInteractionMode,
            modeProfileID: modeProfileID,
            ownerAccountID: APISessionContext.authenticatedOwnerAccountID,
            cwd: cwd,
            lineageKind: lineageKind,
            origin: origin
        )
        try? await orchestrator.adoptPersistedNewConversationSelection(newConversation)
        return newConversation.id
    }

    func updateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        try await updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: model,
            userSystemPrompt: userSystemPrompt,
            skipControlPlaneRevisionBump: false
        )
    }

    func updateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        try await updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: thinkingConfig,
            skipControlPlaneRevisionBump: false
        )
    }

    private func applyConversationPatch(
        conversationID: UUID,
        patch: ConversationPatch,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        guard let current = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        if patch.expectedRevision != current.controlPlaneRevision {
            throw ConversationServiceError.conversationRevisionMismatch(
                conversationID: conversationID,
                expectedRevision: patch.expectedRevision,
                currentRevision: current.controlPlaneRevision
            )
        }

        let mergedTopic = patch.topic != nil ? patch.topic : current.topic
        let mergedDescription = patch.description != nil ? patch.description : current.description
        let mergedMetadata = patch.metadata != nil ? patch.metadata : current.metadata
        if patch.topic != nil || patch.description != nil || patch.metadata != nil || patch.interactionMode != nil || patch.modeProfileID != nil {
            try await updateConversationMetadata(
                conversationID: conversationID,
                topic: mergedTopic,
                description: mergedDescription,
                metadata: mergedMetadata,
                interactionMode: patch.interactionMode,
                modeProfileID: patch.modeProfileID,
                interactionModeChangeInitiator: "patch",
                interactionModeChangeReason: nil,
                skipControlPlaneRevisionBump: true
            )
        }
        if let routingModelOptions = patch.routingModelOptions {
            try await updateConversationThinkingConfig(
                conversationID: conversationID,
                thinkingConfig: routingModelOptions.thinkingConfig,
                skipControlPlaneRevisionBump: true
            )
        }
        if let routingToolPolicy = patch.routingToolPolicy {
            try await updateConversationRoutingToolPolicy(
                conversationID: conversationID,
                policy: routingToolPolicy,
                skipControlPlaneRevisionBump: true
            )
        }
        if let life = patch.lifecycle {
            try await deps.persistenceDomain.updateConversationLifecycle(
                conversationID: conversationID,
                lifecycle: life
            )
            if life == .archived {
                try await deps.persistenceDomain.routingAppendCheckpointInvalidationAsync(
                    conversationID: conversationID,
                    kinds: ConversationDerivedCheckpointKinds.allInvalidationKinds
                )
                _ = try await deps.persistenceDomain.pruneDerivedArtifactsForConversationAsync(
                    conversationID: conversationID
                )
                await topics.publishCheckpointInvalidationOnTopic(
                    conversationID: conversationID,
                    invalidatedKinds: ConversationDerivedCheckpointKinds.allInvalidationKinds
                )
            }
        }
        if let cwd = patch.cwd {
            _ = try await deps.persistenceDomain.recordHarnessPersistenceCwd(
                conversationID: conversationID,
                cwd: cwd
            )
        }
        await messaging.refreshProjectedConversationMessages(conversationID: conversationID, baseMessagesOverride: nil)
        if !skipControlPlaneRevisionBump {
            try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
        }
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
        let resolvedInteractionMode = await resolvedInteractionModeForModeProfile(
            modeProfileID: modeProfileID,
            fallbackInteractionMode: interactionMode
        )
        guard let prior = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let transition = try await predictedTransitionState(
            prior: prior,
            requestedInteractionMode: resolvedInteractionMode,
            requestedModeProfileID: modeProfileID
        )
        let touchesTransitionState = transition.didChange

        if touchesTransitionState, let activeRunID = await activeStreamingRunID(for: conversationID) {
            if Self.isDeferrableToolModeTransition(
                initiator: interactionModeChangeInitiator,
                reason: interactionModeChangeReason
            ) {
                pendingModeTransitions[PendingModeTransitionKey(
                    conversationID: conversationID,
                    runID: activeRunID
                )] = PendingModeTransition(
                    topic: topic,
                    description: description,
                    metadata: metadata,
                    interactionMode: resolvedInteractionMode,
                    modeProfileID: modeProfileID,
                    initiator: interactionModeChangeInitiator ?? "tool",
                    reason: interactionModeChangeReason,
                    skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
                )
                deps.logger?.info(
                    "[ConversationControlPlaneServiceImpl] deferred mode transition conversationID=\(conversationID.uuidString) activeRunID=\(activeRunID.uuidString) reason=\(interactionModeChangeReason ?? "nil")"
                )
                return
            }
            throw ConversationServiceError.conversationModeChangeRunInProgress(
                conversationID: conversationID,
                activeRunID: activeRunID
            )
        }

        guard touchesTransitionState else {
            _ = try await deps.persistenceDomain.updateConversationMetadata(
                conversationID: conversationID,
                topic: topic,
                description: description,
                metadata: metadata,
                interactionMode: resolvedInteractionMode,
                modeProfileID: modeProfileID,
                skipControlPlaneRevisionBump: true
            )
            if !skipControlPlaneRevisionBump {
                try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
            }
            return
        }

        try await applyModeTransition(
            prior: prior,
            transition: transition,
            conversationID: conversationID,
            topic: topic,
            description: description,
            metadata: metadata,
            resolvedInteractionMode: resolvedInteractionMode,
            modeProfileID: modeProfileID,
            initiator: interactionModeChangeInitiator ?? "api",
            reason: interactionModeChangeReason,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    func flushPendingModeTransition(
        conversationID: UUID,
        runID: UUID,
        terminalCategory: ConversationRunTerminalCategory?
    ) async {
        let key = PendingModeTransitionKey(conversationID: conversationID, runID: runID)
        guard let pending = pendingModeTransitions.removeValue(forKey: key) else { return }
        guard terminalCategory == .naturalStop else {
            deps.logger?.info(
                "[ConversationControlPlaneServiceImpl] discarded deferred mode transition conversationID=\(conversationID.uuidString) runID=\(runID.uuidString) terminalCategory=\(terminalCategory?.rawValue ?? "nil")"
            )
            return
        }
        guard let prior = await deps.persistenceDomain.modelConversation(id: conversationID) else { return }
        let transition: PredictedTransitionState
        do {
            transition = try await predictedTransitionState(
                prior: prior,
                requestedInteractionMode: pending.interactionMode,
                requestedModeProfileID: pending.modeProfileID
            )
        } catch {
            deps.logger?.warning("[ConversationControlPlaneServiceImpl] deferred mode transition prediction failed: \(error)")
            return
        }
        guard transition.didChange else { return }
        do {
            try await applyModeTransition(
                prior: prior,
                transition: transition,
                conversationID: conversationID,
                topic: pending.topic,
                description: pending.description,
                metadata: pending.metadata,
                resolvedInteractionMode: pending.interactionMode,
                modeProfileID: pending.modeProfileID,
                initiator: pending.initiator,
                reason: pending.reason,
                skipControlPlaneRevisionBump: pending.skipControlPlaneRevisionBump
            )
            deps.logger?.info(
                "[ConversationControlPlaneServiceImpl] applied deferred mode transition conversationID=\(conversationID.uuidString) runID=\(runID.uuidString)"
            )
        } catch {
            deps.logger?.warning("[ConversationControlPlaneServiceImpl] deferred mode transition apply failed: \(error)")
        }
    }

    func scheduleOrApplyToolModeTransition(
        conversationID: UUID,
        targetMode: InteractionMode,
        modeProfileID: String,
        reason: String
    ) async throws -> ModeTransitionApplyResult {
        guard let prior = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let transition = try await predictedTransitionState(
            prior: prior,
            requestedInteractionMode: targetMode,
            requestedModeProfileID: modeProfileID
        )
        guard transition.didChange else { return .applied }
        if let activeRunID = await activeStreamingRunID(for: conversationID),
           Self.isDeferrableToolModeTransition(initiator: "tool", reason: reason) {
            pendingModeTransitions[PendingModeTransitionKey(
                conversationID: conversationID,
                runID: activeRunID
            )] = PendingModeTransition(
                topic: nil,
                description: nil,
                metadata: nil,
                interactionMode: targetMode,
                modeProfileID: modeProfileID,
                initiator: "tool",
                reason: reason,
                skipControlPlaneRevisionBump: false
            )
            deps.logger?.info(
                "[ConversationControlPlaneServiceImpl] deferred tool mode transition conversationID=\(conversationID.uuidString) activeRunID=\(activeRunID.uuidString) reason=\(reason)"
            )
            return .deferredUntilRunCompletes
        }
        try await applyModeTransition(
            prior: prior,
            transition: transition,
            conversationID: conversationID,
            topic: nil,
            description: nil,
            metadata: nil,
            resolvedInteractionMode: targetMode,
            modeProfileID: modeProfileID,
            initiator: "tool",
            reason: reason,
            skipControlPlaneRevisionBump: false
        )
        return .applied
    }

    private static func isDeferrableToolModeTransition(initiator: String?, reason: String?) -> Bool {
        guard initiator == "tool" else { return false }
        guard let reason else { return false }
        return reason == ModeTransitionToolProvider.exitPlanModeToolName
            || reason == ModeTransitionToolProvider.enterPlanModeToolName
    }

    private func applyModeTransition(
        prior: ModelConversation,
        transition: PredictedTransitionState,
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        resolvedInteractionMode: InteractionMode?,
        modeProfileID: String?,
        initiator: String,
        reason: String?,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        let transitionContext = ModeTransitionContext(
            conversationID: conversationID,
            fromProfile: await resolvedModeProfile(for: prior),
            toProfile: (await deps.modeRegistry.resolveReportingFallback(
                modeId: transition.toModeProfileID,
                logger: deps.logger,
                fallbackModeId: InteractionMode.chat.rawValue
            )).profile,
            initiatedBy: initiator,
            reason: reason
        )

        var didRunExitHooks = false
        var didPersistTransitionState = false
        var didRunEnterHooks = false
        do {
            try await orchestrator.runTransitionHookIDs(
                transitionContext.fromProfile.hooks.onExit,
                context: transitionContext
            )
            didRunExitHooks = true
            let persistedTransitionState = try await deps.persistenceDomain.updateConversationMetadata(
                conversationID: conversationID,
                topic: topic,
                description: description,
                metadata: metadata,
                interactionMode: resolvedInteractionMode,
                modeProfileID: modeProfileID,
                skipControlPlaneRevisionBump: true
            )
            guard persistedTransitionState else {
                if !skipControlPlaneRevisionBump {
                    try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
                }
                return
            }
            didPersistTransitionState = true
            try await orchestrator.runTransitionHookIDs(
                transitionContext.toProfile.hooks.onEnter,
                context: transitionContext
            )
            didRunEnterHooks = true
            let payload = InteractionModeChangedEventPayload(
                fromMode: prior.interactionMode.rawValue,
                toMode: transition.toInteractionMode.rawValue,
                fromProfileID: prior.modeProfileID ?? prior.interactionMode.rawValue,
                toProfileID: transition.toModeProfileID,
                fromPhase: prior.interactionMode == .agent ? "build" : "plan",
                toPhase: transition.toInteractionMode == .agent ? "build" : "plan",
                initiatedBy: initiator,
                reason: reason
            )
            try await deps.persistenceDomain.routingAppendInteractionModeChangedEventAsync(
                conversationID: conversationID,
                payload: payload,
                expectedRawSequence: nil
            )
            if !skipControlPlaneRevisionBump {
                try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
            }
        } catch {
            await orchestrator.rollbackMetadataTransition(
                conversationID: conversationID,
                prior: prior,
                transitionContext: transitionContext,
                didPersistTransitionState: didPersistTransitionState,
                didRunExitHooks: didRunExitHooks,
                didRunEnterHooks: didRunEnterHooks
            )
            throw error
        }
    }

    private func updateConversationModelAndUserPrompt(
        conversationID: UUID,
        model: Model?,
        userSystemPrompt: String?,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        guard let prior = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let modelChange = model.map { $0.id != prior.model.id } ?? false
        let promptChange: Bool = {
            guard let prompt = userSystemPrompt else { return false }
            return prompt != prior.systemPrompt
        }()

        guard modelChange || promptChange else {
            throw ConversationServiceError.noMeaningfulModelOrPromptChange
        }

        if (modelChange || promptChange),
           let activeRunID = await activeStreamingRunID(for: conversationID) {
            throw ConversationServiceError.conversationModelOrPromptChangeRunInProgress(
                conversationID: conversationID,
                activeRunID: activeRunID
            )
        }

        let updatedConversation = try await deps.persistenceDomain.updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: model,
            userSystemPrompt: userSystemPrompt,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )

        await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: updatedConversation)

        if modelChange || promptChange {
            await orchestratorRuntime.invalidateOrchestrator()
        }
    }

    private func updateConversationRoutingToolPolicy(
        conversationID: UUID,
        policy: ConversationExplicitToolPolicy,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        guard var conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        var prefs = conversation.routingPrefs ?? ConversationRoutingPrefs()
        prefs.explicitToolPolicy = policy
        conversation.routingPrefs = prefs
        await deps.persistenceDomain.replaceConversationInRegistry(conversation)
        if let refreshed = await deps.persistenceDomain.modelConversation(id: conversationID) {
            try await deps.persistenceDomain.syncConversationCatalogStateToSessionBackend(conversation: refreshed)
        }
        if !skipControlPlaneRevisionBump {
            try await deps.persistenceDomain.bumpControlPlaneRevision(conversationID: conversationID)
        }
        await orchestratorRuntime.invalidateOrchestrator()
    }

    private func updateConversationThinkingConfig(
        conversationID: UUID,
        thinkingConfig: ThinkingConfig?,
        skipControlPlaneRevisionBump: Bool
    ) async throws {
        try await deps.persistenceDomain.updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: thinkingConfig,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
        await orchestratorRuntime.invalidateOrchestrator()
    }

    private func activeStreamingRunID(for conversationID: UUID) async -> UUID? {
        let lifecycle = await orchestrationCore.lifecycleSnapshot(for: conversationID)
        guard lifecycle.generationTask != nil,
              lifecycle.activeStreamingConversationID == conversationID
        else {
            return nil
        }
        return lifecycle.currentStreamingRunID
    }

    private struct PredictedTransitionState: Sendable {
        let toInteractionMode: InteractionMode
        let toModeProfileID: String
        let didChange: Bool
    }

    private func predictedTransitionState(
        prior: ModelConversation,
        requestedInteractionMode: InteractionMode?,
        requestedModeProfileID: String?
    ) async throws -> PredictedTransitionState {
        var targetMode = prior.interactionMode
        var targetProfileID = prior.modeProfileID ?? prior.interactionMode.rawValue

        if let requestedInteractionMode {
            targetMode = requestedInteractionMode
            targetProfileID = requestedModeProfileID ?? targetMode.rawValue
        } else if let requestedModeProfileID {
            targetProfileID = requestedModeProfileID
            targetMode = (await deps.modeRegistry.resolveReportingFallback(
                modeId: requestedModeProfileID,
                logger: deps.logger,
                fallbackModeId: InteractionMode.chat.rawValue
            )).profile.interactionMode
        }

        let didChange = targetMode != prior.interactionMode
            || targetProfileID != (prior.modeProfileID ?? prior.interactionMode.rawValue)
        return PredictedTransitionState(
            toInteractionMode: targetMode,
            toModeProfileID: targetProfileID,
            didChange: didChange
        )
    }

    private func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        (await deps.modeRegistry.resolveReportingFallback(
            modeId: conversation.modeProfileID ?? conversation.interactionMode.rawValue,
            logger: deps.logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile
    }

    private func resolvedInteractionModeForModeProfile(
        modeProfileID: String?,
        fallbackInteractionMode: InteractionMode?
    ) async -> InteractionMode? {
        guard let modeProfileID else { return fallbackInteractionMode }
        return (await deps.modeRegistry.resolveReportingFallback(
            modeId: modeProfileID,
            logger: deps.logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile.interactionMode
    }
}
