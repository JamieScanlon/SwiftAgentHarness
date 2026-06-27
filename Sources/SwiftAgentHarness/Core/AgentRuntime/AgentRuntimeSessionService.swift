import Combine
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

/// Agent-runtime session state and streaming orchestration (Slice 3 migration).
public actor AgentRuntimeSessionService {
    typealias Configuration = HarnessRuntimeSession.Configuration

    let deps: ConversationRuntimeDependencies
    let messaging: ConversationMessagingPort
    let topics: ConversationTopicPublicationPort
    let orchestratorPort: OrchestratorSessionPort
    let selection: ConversationSelectionAccessing
    let outbound: AgentRuntimeOutboundCollaborators
    let orchestrationCore: AgentRuntimeOrchestrationCore
    var sessionState = AgentRuntimeSessionState()

    var orchestratorListenerTasks = OrchestratorListenerTasks()
    var activeListenerConversationID: UUID?

    private var turnLoopStopRequestedConversationIDs: Set<UUID> = []
    private var activeTurnConfigurationsByRunID: [UUID: (conversationID: UUID, configuration: AgentRuntimeTurnConfiguration)] = [:]
    private var activeRunOrchestratorHandles: [UUID: OrchestratorHandle] = [:]
    var agentLoopPartialContinuation: AsyncStream<ChatStreamingPartial>.Continuation?
    private(set) var testing_clearBindingCallCount = 0

    nonisolated(unsafe) private var subAgentSpawnService: SubAgentSpawnService?
    nonisolated(unsafe) private var controlPlane: (any ConversationControlPlaneServicing)?

    init(
        deps: ConversationRuntimeDependencies,
        messaging: ConversationMessagingPort,
        topics: ConversationTopicPublicationPort,
        orchestratorPort: OrchestratorSessionPort,
        selection: ConversationSelectionAccessing,
        outbound: AgentRuntimeOutboundCollaborators,
        orchestrationCore: AgentRuntimeOrchestrationCore
    ) {
        self.deps = deps
        self.messaging = messaging
        self.topics = topics
        self.orchestratorPort = orchestratorPort
        self.selection = selection
        self.outbound = outbound
        self.orchestrationCore = orchestrationCore
    }

    nonisolated func installSubAgentSpawnService(_ spawnService: SubAgentSpawnService) {
        subAgentSpawnService = spawnService
    }

    nonisolated func installControlPlane(_ controlPlane: any ConversationControlPlaneServicing) {
        self.controlPlane = controlPlane
    }

    func flushPendingModeTransitionAfterRunTerminal(
        conversationID: UUID,
        runID: UUID,
        terminalCategory: ConversationRunTerminalCategory?
    ) async {
        guard let controlPlane else { return }
        await controlPlane.flushPendingModeTransition(
            conversationID: conversationID,
            runID: runID,
            terminalCategory: terminalCategory
        )
    }

    func subAgentSpawnServiceForRuntime() -> SubAgentSpawnService? {
        subAgentSpawnService
    }

    func clearOrchestratorBinding() async {
        testing_clearBindingCallCount += 1
        orchestratorListenerTasks.cancelAllListeners()
        await orchestrationCore.clearBinding()
    }

    func requestTurnLoopStop(conversationID: UUID) async {
        turnLoopStopRequestedConversationIDs.insert(conversationID)
    }

    func turnLoopStopRequested(for conversationID: UUID) -> Bool {
        turnLoopStopRequestedConversationIDs.contains(conversationID)
    }

    func clearTurnLoopStopRequest(for conversationID: UUID? = nil) {
        if let conversationID {
            turnLoopStopRequestedConversationIDs.remove(conversationID)
        } else {
            turnLoopStopRequestedConversationIDs.removeAll()
        }
    }

    func registerActiveTurnConfiguration(
        conversationID: UUID,
        runID: UUID?,
        configuration: AgentRuntimeTurnConfiguration
    ) {
        guard let runID else { return }
        activeTurnConfigurationsByRunID[runID] = (conversationID, configuration)
    }

    func activeTurnConfiguration(
        conversationID: UUID,
        runID: UUID?
    ) -> AgentRuntimeTurnConfiguration? {
        guard let runID,
              let entry = activeTurnConfigurationsByRunID[runID],
              entry.conversationID == conversationID else {
            return nil
        }
        return entry.configuration
    }

    func clearActiveTurnConfiguration(runID: UUID?) {
        guard let runID else { return }
        activeTurnConfigurationsByRunID.removeValue(forKey: runID)
    }

    private func configurationApplyingInteractiveDefaults(_ configuration: Configuration) -> Configuration {
        let runtimeConfiguration = MessageOutputTurnConfiguration.applyingInteractiveDefaultsWhenMissing(
            to: AgentRuntimeTurnConfiguration(managerConfiguration: configuration)
        )
        return Configuration(runtimeConfiguration: runtimeConfiguration)
    }

    // MARK: - Runtime streaming API surface

    func serviceRuntimeMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await buildRuntimeMessageStream(for: conversationID)
    }

    func messageStream(for conversationID: UUID? = nil) async throws -> AsyncStream<[Message]> {
        try await buildRuntimeMessageStream(for: conversationID)
    }

    func cancelMessageStream() async {
        cancelRuntimeMessageStream()
    }

    func serviceRuntimeSendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        guard let conv = await modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return try await sendMessageAndStreamResponse(
            text,
            images: images,
            forConversation: conv,
            shouldTouchCurrentMessagesProjection: false,
            configuration: Configuration(runtimeConfiguration: configuration)
        )
    }

    func sendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        guard let conv = await modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return try await sendMessageAndStreamResponse(
            text,
            images: images,
            forConversation: conv,
            shouldTouchCurrentMessagesProjection: false,
            configuration: configuration
        )
    }

    private func sendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        forConversation initial: ModelConversation,
        shouldTouchCurrentMessagesProjection: Bool,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        let conversation = initial
        let logger = deps.logger
        logger?.info("[AgentRuntimeSessionService] Sending message: length=\(text.count), images=\(images.count)")

        guard conversation.isModelAvailable else {
            throw ConversationServiceError.modelUnavailable
        }

        let runtimeLifecycle = await currentLifecycleSnapshot(for: conversation.id)
        if runtimeLifecycle.generationTask != nil,
           runtimeLifecycle.activeStreamingConversationID == conversation.id,
           let busyRun = runtimeLifecycle.currentStreamingRunID {
            throw ConversationServiceError.conversationRunInProgress(conversationID: conversation.id, activeRunID: busyRun)
        }

        var effectiveText = text
        var effectiveConfiguration = configuration

        switch try await processControlInputBoundary(
            text: text,
            conversationID: conversation.id,
            configuration: configuration
        ) {
        case .shortCircuit(let response):
            return response
        case let .continueTurn(modelText, patch, preTurnAckContent):
            effectiveText = modelText
            effectiveConfiguration.turnThinkingOverride = patch.turnThinkingOverride
            effectiveConfiguration.turnModelSlug = patch.turnModelSlug
            if let preTurnAckContent, !preTurnAckContent.isEmpty {
                try await savePreTurnAcknowledgement(preTurnAckContent, conversationID: conversation.id)
            }
        case .passthrough:
            break
        }

        effectiveConfiguration = configurationApplyingInteractiveDefaults(effectiveConfiguration)

        let runID = UUID()
        let sessionLaneKey = await sessionLaneKey(conversationID: conversation.id)
        if let admission = await deps.runtimeLaneCoordinator.tryAcquireMainRun(sessionKey: sessionLaneKey, runID: runID) {
            throw await runtimeSessionError(for: admission, conversationID: conversation.id, fallbackRunID: runID)
        }

        let resolvedConfiguration = await configurationApplyingTrustPolicy(effectiveConfiguration)
        let sendingConversationID = conversation.id

        do {
            guard let acquisition = await orchestratorRuntime.acquireOrchestrator(
                conversation: conversation,
                model: conversation.model
            ) else {
                throw ConversationServiceError.failedToInitialize
            }
            activeRunOrchestratorHandles[runID] = acquisition.handle
            await orchestratorPort.startOrchestratorStateListeners(for: sendingConversationID)
            guard let orchestrator = await orchestrationCore.orchestrator(for: sendingConversationID) else {
                throw ConversationServiceError.failedToInitialize
            }
            await invokeTestingPreRunStateSendHook(for: conversation)

            let trustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(resolvedConfiguration.inputTrustRaw)
            let newMessage = Message(id: UUID(), role: .user, content: effectiveText, images: images, inputTrustRaw: trustRaw)
            _ = try await saveMessageToCache(
                newMessage,
                for: conversation.id,
                expectedPreviousTailHarnessMessageID: resolvedConfiguration.expectedPreviousTailHarnessMessageID,
                transcriptRunID: runID
            )
            guard var conversation = await modelConversation(id: sendingConversationID) else {
                throw ConversationServiceError.conversationNotFound
            }
            conversation.turns = await transformedTurns(
                messages: conversation.messages,
                interactionMode: conversation.interactionMode,
                previousTurns: conversation.turns
            )
            conversation.state = .generating
            conversation.agenticPhase = .started
            conversation.llmRequestPhase = .queued
            conversation.currentRunID = runID
            conversation.lastActiveAt = Date()
            await updateConversation(conversation)
            if shouldTouchCurrentMessagesProjection {
                await touchCurrentMessagesProjection(for: conversation)
            }
            await updateLifecycle(for: sendingConversationID) { lifecycle in
                lifecycle.currentStreamingRunID = runID
            }

            let (turnStateStream, turnContinuation) = AsyncStream.makeStream(
                of: ConversationOrchestrationState.self,
                bufferingPolicy: .bufferingNewest(64)
            )
            setTurnStateContinuation(turnContinuation)
            if let initial = await buildOrchestrationSnapshot(
                forStreamingConversation: sendingConversationID,
                isTerminalSnapshotAfterCompletion: false,
                forceStreamingPhases: false
            ) {
                turnContinuation.yield(initial)
            }

            let partialContent = await buildRuntimePartialContentStream(
                orchestrator: orchestrator,
                conversationID: sendingConversationID,
                runID: runID
            )
            await startStreamingOrchestrationTask(
                sendingConversationID: sendingConversationID,
                turnLoopAnchorUserMessageID: newMessage.id,
                configuration: resolvedConfiguration,
                orchestrator: orchestrator
            )
            return ChatStreamResponse(
                partialContent: partialContent,
                orchestrationState: turnStateStream,
                conversationID: sendingConversationID,
                runID: runID,
                messageID: newMessage.id
            )
        } catch {
            await deps.runtimeLaneCoordinator.releaseMainRun(sessionKey: sessionLaneKey, runID: runID)
            throw error
        }
    }

    func serviceRuntimeRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        try await revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: messageID,
            configuration: Configuration(runtimeConfiguration: configuration)
        )
    }

    func revertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        await cancelGeneration(for: conversationID)
        await orchestrationCore.invalidateOrchestrator(for: conversationID)

        guard var conversation = await modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard conversation.isModelAvailable else {
            throw ConversationServiceError.modelUnavailable
        }
        let sendingConversationID = conversation.id
        let revertRunID = UUID()
        let sessionLaneKey = await sessionLaneKey(conversationID: sendingConversationID)
        if let admission = await deps.runtimeLaneCoordinator.tryAcquireMainRun(sessionKey: sessionLaneKey, runID: revertRunID) {
            throw await runtimeSessionError(for: admission, conversationID: sendingConversationID, fallbackRunID: revertRunID)
        }

        let resolvedConfiguration = configurationApplyingInteractiveDefaults(configuration)

        do {
            let prefixMessages = try await routingRevert(
                conversationID: sendingConversationID,
                userMessageID: messageID
            )
            let revertInvalidationKinds = derivedCheckpointInvalidationKinds()
            try await routingAppendCheckpointInvalidation(
                conversationID: sendingConversationID,
                kinds: revertInvalidationKinds
            )
            await publishCheckpointInvalidation(
                conversationID: sendingConversationID,
                invalidatedKinds: revertInvalidationKinds
            )
            await syncConversationTurns(
                conversationID: sendingConversationID,
                interactionMode: conversation.interactionMode,
                preferredTurns: conversation.turns
            )
            conversation.messages = prefixMessages
            conversation.turns = await transformedTurns(
                messages: prefixMessages,
                interactionMode: conversation.interactionMode,
                previousTurns: conversation.turns
            )
            conversation.state = .generating
            conversation.agenticPhase = .started
            conversation.llmRequestPhase = .queued
            conversation.updatedAt = Date()
            conversation.currentRunID = revertRunID
            await updateConversation( conversation)
            if await shouldMirrorSelectionToGlobalChatState() {
                await touchCurrentMessagesProjection(for: conversation)
            }
            await updateLifecycle(for: sendingConversationID) { lifecycle in
                lifecycle.currentStreamingRunID = revertRunID
            }

            guard let acquisition = await orchestratorRuntime.acquireOrchestrator(
                conversation: conversation,
                model: conversation.model
            ) else {
                throw ConversationServiceError.failedToInitialize
            }
            activeRunOrchestratorHandles[revertRunID] = acquisition.handle
            await orchestratorPort.startOrchestratorStateListeners(for: sendingConversationID)
            guard let orchestrator = await orchestrationCore.orchestrator(for: sendingConversationID) else {
                throw ConversationServiceError.failedToInitialize
            }

            let (turnStateStream, turnContinuation) = AsyncStream.makeStream(
                of: ConversationOrchestrationState.self,
                bufferingPolicy: .bufferingNewest(64)
            )
            setTurnStateContinuation(turnContinuation)
            if let initial = await buildOrchestrationSnapshot(
                forStreamingConversation: sendingConversationID,
                isTerminalSnapshotAfterCompletion: false,
                forceStreamingPhases: false
            ) {
                turnContinuation.yield(initial)
            }

            let partialContent = await buildRuntimePartialContentStream(
                orchestrator: orchestrator,
                conversationID: sendingConversationID,
                runID: revertRunID
            )
            await startStreamingOrchestrationTask(
                sendingConversationID: sendingConversationID,
                turnLoopAnchorUserMessageID: messageID,
                configuration: resolvedConfiguration,
                orchestrator: orchestrator
            )
            return ChatStreamResponse(
                partialContent: partialContent,
                orchestrationState: turnStateStream,
                conversationID: sendingConversationID,
                runID: revertRunID
            )
        } catch {
            await deps.runtimeLaneCoordinator.releaseMainRun(sessionKey: sessionLaneKey, runID: revertRunID)
            throw error
        }
    }

    func serviceRuntimeSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        try await splitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            configuration: Configuration(runtimeConfiguration: configuration)
        )
    }

    func splitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        let (newConversationID, anchorNewId) = try await persistSplit(
            sourceConversationID: conversationID,
            atUserMessageID: messageID
        )

        await cancelGeneration(for: newConversationID)
        await orchestrationCore.invalidateOrchestrator(for: newConversationID)

        guard var conv = await modelConversation(id: newConversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let sendingConversationID = conv.id
        let splitRunID = UUID()
        await updateLifecycle(for: sendingConversationID) { lifecycle in
            lifecycle.currentStreamingRunID = splitRunID
        }
        conv.state = .generating
        conv.agenticPhase = .started
        conv.llmRequestPhase = .queued
        conv.currentRunID = splitRunID
        conv.lastActiveAt = Date()
        await updateConversation( conv)
        if await shouldMirrorSelectionToGlobalChatState() {
            await touchCurrentMessagesProjection(for: conv)
        }

        guard let acquisition = await orchestratorRuntime.acquireOrchestrator(
            conversation: conv,
            model: conv.model
        ) else {
            throw ConversationServiceError.failedToInitialize
        }
        activeRunOrchestratorHandles[splitRunID] = acquisition.handle
        await orchestratorPort.startOrchestratorStateListeners(for: sendingConversationID)
        guard let orchestrator = await orchestrationCore.orchestrator(for: sendingConversationID) else {
            throw ConversationServiceError.failedToInitialize
        }

        let resolvedConfiguration = configurationApplyingInteractiveDefaults(configuration)

        let (turnStateStream, turnContinuation) = AsyncStream.makeStream(
            of: ConversationOrchestrationState.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        setTurnStateContinuation(turnContinuation)
        if let initial = await buildOrchestrationSnapshot(
            forStreamingConversation: sendingConversationID,
            isTerminalSnapshotAfterCompletion: false,
            forceStreamingPhases: false
        ) {
            turnContinuation.yield(initial)
        }

        let partialContent = await buildRuntimePartialContentStream(
            orchestrator: orchestrator,
            conversationID: sendingConversationID,
            runID: splitRunID
        )
        await startStreamingOrchestrationTask(
            sendingConversationID: sendingConversationID,
            turnLoopAnchorUserMessageID: anchorNewId,
            configuration: resolvedConfiguration,
            orchestrator: orchestrator
        )
        return ChatStreamResponse(
            partialContent: partialContent,
            orchestrationState: turnStateStream,
            conversationID: sendingConversationID,
            runID: splitRunID
        )
    }

    func cancelGeneration() async {
        await cancelGeneration(for: nil)
    }

    func cancelGeneration(for conversationID: UUID) async {
        await cancelGeneration(for: Optional(conversationID))
    }

    func cancelGeneration(for conversationID: UUID?) async {
        let runtimeLifecycle = if let conversationID {
            await currentLifecycleSnapshot(for: conversationID)
        } else {
            await currentLifecycleSnapshot()
        }
        let hadTask = runtimeLifecycle.generationTask != nil
        if let conversationID {
            await updateLifecycle(for: conversationID) { lifecycle in
                lifecycle.generationTask?.cancel()
                lifecycle.generationTask = nil
                lifecycle.isContentStreamingActive = false
            }
        } else {
            await updateLifecycle { lifecycle in
                lifecycle.generationTask?.cancel()
                lifecycle.generationTask = nil
                lifecycle.isContentStreamingActive = false
            }
        }
        let targetConversationID = conversationID ?? runtimeLifecycle.activeStreamingConversationID
        if let targetConversationID,
           let orchestrator = await orchestrationCore.orchestrator(for: targetConversationID) {
            let activeRuns = await orchestrator.recoverableActiveRunsSnapshot()
            for activeRun in activeRuns {
                _ = await orchestrator.cancelRun(runID: activeRun.runID)
            }
        }
        if !hadTask {
            if let activeConversationID = runtimeLifecycle.activeStreamingConversationID,
               let activeRunID = runtimeLifecycle.currentStreamingRunID {
                let sessionLaneKey = await sessionLaneKey(conversationID: activeConversationID)
                Task { [runtimeLaneCoordinator = deps.runtimeLaneCoordinator] in
                    await runtimeLaneCoordinator.releaseMainRun(sessionKey: sessionLaneKey, runID: activeRunID)
                }
            }
            if let conversationID {
                await updateLifecycle(for: conversationID) { lifecycle in
                    lifecycle.currentStreamingRunID = nil
                    lifecycle.activeStreamingConversationID = nil
                    lifecycle.activeAnchorUserMessageID = nil
                    lifecycle.isContentStreamingActive = false
                }
            } else {
                await updateLifecycle { lifecycle in
                    lifecycle.currentStreamingRunID = nil
                    lifecycle.activeStreamingConversationID = nil
                    lifecycle.activeAnchorUserMessageID = nil
                    lifecycle.isContentStreamingActive = false
                }
            }
        }
    }

    func releaseRunOrchestrator(runID: UUID) async {
        guard let handle = activeRunOrchestratorHandles.removeValue(forKey: runID) else { return }
        await orchestratorRuntime.releaseOrchestrator(handle)
    }

    func storeRunOrchestratorHandle(runID: UUID, handle: OrchestratorHandle) {
        activeRunOrchestratorHandles[runID] = handle
    }

    func cancelActiveRunForAPI(conversationID: UUID, runID: UUID) async throws {
        guard await modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        let runtimeLifecycle = await currentLifecycleSnapshot(for: conversationID)
        guard runID == runtimeLifecycle.currentStreamingRunID,
              conversationID == runtimeLifecycle.activeStreamingConversationID else {
            throw ConversationServiceError.cancelRunNotActive
        }
        let anchorUserMessageID = runtimeLifecycle.activeAnchorUserMessageID
        await cancelGeneration(for: conversationID)
        await subAgentSpawnServiceForRuntime()?.cancelActiveInvocationsForParent(
            parentConversationID: conversationID
        )
        await requestTurnLoopStop(conversationID: conversationID)
        if let anchorUserMessageID {
            await stripRunTail(
                conversationID: conversationID,
                anchorUserMessageID: anchorUserMessageID
            )
        }
        await messaging.applyStreamingUserCancellation(conversationID: conversationID)
    }

    func cancelSubAgentRun(conversationID: UUID, runID: UUID) async {
        let lifecycle = await currentLifecycleSnapshot(for: conversationID)
        if lifecycle.currentStreamingRunID == runID {
            await cancelGeneration(for: conversationID)
        } else if let orchestrator = await orchestrationCore.orchestrator(for: conversationID) {
            let activeRuns = await orchestrator.recoverableActiveRunsSnapshot()
            for activeRun in activeRuns {
                _ = await orchestrator.cancelRun(runID: activeRun.runID)
            }
        }
        await releaseRunOrchestrator(runID: runID)
    }

    func listRunsForAPI(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        let lifecycle = await currentLifecycleSnapshot(for: conversationID)
        return await listRunsProjectionForAPI(
            conversationID: conversationID,
            filter: filter,
            activeRuntimeRunID: lifecycle.currentStreamingRunID,
            activeRuntimeConversationID: lifecycle.activeStreamingConversationID
        )
    }

    func getRunForAPI(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        let lifecycle = await currentLifecycleSnapshot(for: conversationID)
        return await getRunProjectionForAPI(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: includeProjectionDetail,
            activeRuntimeRunID: lifecycle.currentStreamingRunID,
            activeRuntimeConversationID: lifecycle.activeStreamingConversationID
        )
    }
}

extension AgentRuntimeSessionService: AgentRuntimeOrchestratorBinding {
    func orchestrator(for conversationID: UUID) async -> SwiftAgentKitOrchestrator? {
        await orchestrationCore.orchestrator(for: conversationID)
    }
    func lifecycleSnapshot(for conversationID: UUID?) async -> ChatRuntimeLifecycle {
        await currentLifecycleSnapshot(for: conversationID)
    }
    func acquireOrchestrator(
        conversationID: UUID,
        modelName: String,
        buildIfMissing: @escaping OrchestratorPoolBuildFactory
    ) async -> OrchestratorAcquisition? {
        await orchestrationCore.acquireOrchestrator(
            conversationID: conversationID,
            modelName: modelName,
            buildIfMissing: buildIfMissing
        )
    }
    func releaseOrchestrator(_ handle: OrchestratorHandle) async {
        await orchestrationCore.releaseOrchestrator(handle)
    }
    func invalidateOrchestrator(for conversationID: UUID) async {
        await orchestrationCore.invalidateOrchestrator(for: conversationID)
    }
}

extension AgentRuntimeSessionService: AgentRuntimeOrchestrationEmitting {}

extension AgentRuntimeSessionService: AgentRuntimeRunControlling {}

extension AgentRuntimeSessionService: AgentRuntimeResidualStateReading {}

extension AgentRuntimeSessionService: AgentRuntimeTokenSnapshotting {}

extension AgentRuntimeSessionService: AgentRuntimeLaneErrorMapping {}

extension AgentRuntimeSessionService: AgentRuntimeStreamingServicing {}
