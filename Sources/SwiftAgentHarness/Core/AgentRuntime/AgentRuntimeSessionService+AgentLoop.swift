import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func bootstrapContextEngineLifecycle(conversationID: UUID, runID: UUID?) async {
        _ = await deps.contextEngine.bootstrap(
            request: ContextEngineBootstrapRequest(
                conversationID: conversationID,
                runID: runID
            )
        )
    }

    func runtimeConversation(id: UUID) async -> ModelConversation? {
        await modelConversation(id: id)
    }

    func consumeTimedOutToolApprovalsForRuntime(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int?,
        modelID: UUID?,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        await toolApproval.consumeTimedOutToolApprovalsForRuntime(
            conversationID: conversationID,
            runID: runID,
            iteration: iteration,
            modelID: modelID,
            lifecycleEmitter: lifecycleEmitter
        )
    }

    func configurationApplyingToolApprovals(
        _ configuration: AgentRuntimeTurnConfiguration,
        conversationID: UUID,
        runID: UUID?
    ) async -> AgentRuntimeTurnConfiguration {
        let applied = await toolApproval.configurationApplyingToolApprovals(
            agentLoopManagerConfiguration(from: configuration),
            conversationID: conversationID,
            runID: runID
        )
        return agentLoopRuntimeConfiguration(from: applied)
    }

    func allToolRegistryEntriesForOrchestration(orchestrator: SwiftAgentKitOrchestrator) async -> [ToolRegistryEntry] {
        await orchestratorRuntime.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
    }

    func buildToolTurnPolicySnapshot(
        allEntries: [ToolRegistryEntry],
        conversation: ModelConversation,
        configuration: AgentRuntimeTurnConfiguration
    ) async -> RuntimeToolTurnPolicySnapshot {
        await orchestratorRuntime.buildToolTurnPolicySnapshot(
            allEntries: allEntries,
            conversation: conversation,
            configuration: agentLoopManagerConfiguration(from: configuration)
        )
    }

    func approvalContractSpec(
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool
    ) async -> ToolApprovalContractSpec {
        toolApproval.approvalContractSpec(toolName: toolName, route: route, isElevated: isElevated)
    }

    func registerPendingToolApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        isElevated: Bool
    ) async -> Bool {
        await toolApproval.registerPendingToolApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            isElevated: isElevated,
            requestedAt: Date()
        )
    }

    func waitForToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute
    ) async throws -> ToolApprovalResolution {
        try await toolApproval.waitForToolApprovalResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
    }

    func runtimeIsHaltingToolCall(toolName: String, effectiveEntries: [ToolRegistryEntry]) async -> Bool {
        await orchestratorPort.isHaltingToolCallForRuntime(toolName: toolName, effectiveEntries: effectiveEntries)
    }

    func rollbackLatestStalledAssistantTurn(conversationID: UUID, assistantMessageID: UUID?) async {
        await messaging.rollbackLatestAssistantTurnForRuntime(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID
        )
    }

    func stampAssistantFinishReason(
        conversationID: UUID,
        messageID: UUID,
        finishReason: String
    ) async {
        do {
            try await deps.persistenceDomain.stampAssistantFinishReasonOnTranscript(
                conversationID: conversationID,
                messageID: messageID,
                finishReason: finishReason
            )
        } catch {
            deps.logger?.warning("[AgentLoop] stampAssistantFinishReason failed: \(error)")
        }
    }

    private func agentLoopManagerConfiguration(from runtime: AgentRuntimeTurnConfiguration) -> Configuration {
        Configuration(runtimeConfiguration: runtime)
    }

    private func agentLoopRuntimeConfiguration(from manager: Configuration) -> AgentRuntimeTurnConfiguration {
        AgentRuntimeTurnConfiguration(managerConfiguration: manager)
    }

    func beginAgentLoopPartialStream(runID: UUID) -> AsyncStream<ChatStreamingPartial> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ChatStreamingPartial.self,
            bufferingPolicy: .unbounded
        )
        agentLoopPartialContinuationsByRunID.removeValue(forKey: runID)?.finish()
        agentLoopPartialContinuationsByRunID[runID] = continuation
        return stream
    }

    func finishAgentLoopPartialStream(runID: UUID?) {
        guard let runID else { return }
        agentLoopPartialContinuationsByRunID.removeValue(forKey: runID)?.finish()
    }

    func publishAgentLoopDelta(
        _ partial: ChatStreamingPartial,
        conversationID: UUID,
        runID: UUID?
    ) async {
        if let runID {
            agentLoopPartialContinuationsByRunID[runID]?.yield(partial)
        }
        if let payload = Self.agentLoopConversationTopicPayload(for: partial, runID: runID) {
            await publishConversationTopicIfBound(conversationID: conversationID, payload: payload)
        }
    }

    func buildRuntimePartialContentStream(
        orchestrator: SwiftAgentKitOrchestrator,
        conversationID: UUID,
        runID: UUID?
    ) async -> AsyncStream<ChatStreamingPartial> {
        let _ = orchestrator
        return agentLoopPartialContentStream(conversationID: conversationID, runID: runID)
    }

    func agentLoopPartialContentStream(
        conversationID: UUID,
        runID: UUID?
    ) -> AsyncStream<ChatStreamingPartial> {
        guard let runID else {
            return AsyncStream { $0.finish() }
        }
        let base = beginAgentLoopPartialStream(runID: runID)
        return AsyncStream { continuation in
            Task {
                for await partial in base {
                    continuation.yield(partial)
                }
                await self.publishConversationTopicIfBound(
                    conversationID: conversationID,
                    payload: .streamDone
                )
                continuation.finish()
            }
        }
    }

    private static func agentLoopConversationTopicPayload(
        for partial: ChatStreamingPartial,
        runID: UUID?
    ) -> ConversationTopicEventPayload? {
        switch partial {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(
                text: text,
                blockIndex: nil,
                runId: runID,
                callId: nil
            )
        case .reasoning(let text, let blockIndex):
            guard !text.isEmpty else { return nil }
            return ConversationTopicWireEncoding.contentDeltaReasoningFragmentPayload(
                text: text,
                blockIndex: blockIndex,
                runId: runID,
                callId: nil
            )
        case .toolCall(let toolName, let toolCallId, let argumentsFragment, let blockIndex):
            return ConversationTopicWireEncoding.contentDeltaToolCallFragmentPayload(
                toolName: toolName,
                toolCallId: toolCallId,
                argumentsFragment: argumentsFragment,
                blockIndex: blockIndex,
                runId: runID,
                callId: nil
            )
        case .toolCallStarted(let toolName, let toolCallId, let contentIndex):
            return ConversationTopicWireEncoding.contentDeltaToolCallFragmentPayload(
                toolName: toolName,
                toolCallId: toolCallId,
                argumentsFragment: nil,
                blockIndex: contentIndex,
                runId: runID,
                callId: nil
            )
        case .toolCallCompleted(let toolName, let toolCallId, let arguments, let blockIndex):
            return ConversationTopicWireEncoding.contentDeltaToolCallFragmentPayload(
                toolName: toolName,
                toolCallId: toolCallId,
                argumentsFragment: arguments,
                blockIndex: blockIndex,
                runId: runID,
                callId: nil
            )
        case .surfaceIntent(let intent):
            return ConversationTopicWireEncoding.surfaceIntentPayload(intent: intent)
        }
    }

    func makeAgentLoopPorts() -> AgentLoopPorts {
        let contextProjection = outbound.contextProjection
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conversation, orchestrator in
                let _ = orchestrator
                return conversation.model.id
            },
            streamLLM: AgentLoopLLMStreaming.stream
        )
        let contextPort = SessionRuntimeContextPort(
            bootstrapFn: { [self] conversationID, runID in
                await self.bootstrapContextEngineLifecycle(conversationID: conversationID, runID: runID)
                let _ = runID
            },
            assembleFn: { conversationID, phase, ephemeralTail, compaction, configuration in
                guard let conversation = await self.runtimeConversation(id: conversationID) else {
                    throw ConversationServiceError.conversationNotFound
                }
                let base = conversation.messages + ephemeralTail
                let managerConfig = HarnessRuntimeSession.Configuration(
                    enableTools: configuration.enableTools,
                    enableAgents: configuration.enableAgents,
                    allowEscalatedTools: configuration.allowEscalatedTools,
                    preApprovedToolNames: configuration.preApprovedToolNames,
                    expectedPreviousTailHarnessMessageID: configuration.expectedPreviousTailHarnessMessageID,
                    inputTrustRaw: configuration.inputTrustRaw,
                    resolvedInputTrustClass: configuration.resolvedInputTrustClass,
                    ephemeralSystemReminder: configuration.ephemeralSystemReminder
                )
                let gatingOverride: ContextCompactionGatingOptions? = compaction == .forceCompaction
                    ? .forcedReactiveRetry
                    : nil
                return await contextProjection.transformedContextMessages(
                    from: base,
                    conversation: conversation,
                    phase: phase,
                    configuration: managerConfig,
                    gatingOverride: gatingOverride
                )
            },
            afterTurnFn: { [self] conversationID, runID, terminal in
                await self.afterTurnContextEngineLifecycle(
                    conversationID: conversationID,
                    runID: runID,
                    terminalReason: terminal,
                    anchorUserMessageID: nil
                )
            }
        )
        let toolPort = SessionRuntimeToolPort(
            consumeApprovalTimeoutsFn: { [self] conversationID, runID, iteration, modelID, lifecycleEmitter in
                await self.consumeTimedOutToolApprovalsForRuntime(
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    lifecycleEmitter: lifecycleEmitter
                )
            },
            effectiveToolsFn: { [self] conversationID, runID, configuration, orchestrator in
                let approvalConfig = await self.configurationApplyingToolApprovals(
                    configuration,
                    conversationID: conversationID,
                    runID: runID
                )
                guard let conversation = await self.runtimeConversation(id: conversationID) else {
                    return RuntimeToolTurnPolicySnapshot(
                        availabilitySnapshots: [],
                        effectiveEntries: [],
                        dispatchContract: .conservativeDefault
                    )
                }
                let entries = await self.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
                return await self.buildToolTurnPolicySnapshot(
                    allEntries: entries,
                    conversation: conversation,
                    configuration: approvalConfig
                )
            },
            dispatchFn: { [self] call, conversationID, runID, orchestrator, snapshot, configuration, iteration, modelID, runtimePolicy, lifecycleEmitter in
                let conversation = await self.runtimeConversation(id: conversationID)
                let initial = await AgentLoopToolDispatch.dispatch(
                    call: call,
                    conversationID: conversationID,
                    runID: runID,
                    orchestrator: orchestrator,
                    snapshot: snapshot,
                    configuration: configuration,
                    conversation: conversation,
                    gateway: DefaultToolSystemGateway(),
                    parentLookup: { [deps = self.deps] id in
                        await deps.persistenceDomain.modelConversation(id: id)
                    },
                    spawnService: self.subAgentSpawnServiceForRuntime()
                )
                guard case .approvalRequired(let toolName, let toolCallID) = initial else {
                    return initial
                }
                if runtimePolicy.stopOnApprovalRequest == true {
                    return initial
                }
                let evaluation = snapshot.availabilitySnapshots.first(where: { $0.entry.name == toolName })
                let route = evaluation?.decision.approvalRoute ?? .user
                let isElevated = evaluation?.decision.isElevated ?? false
                _ = await self.registerPendingToolApproval(
                    conversationID: conversationID,
                    runID: runID,
                    toolName: toolName,
                    route: route,
                    isElevated: isElevated
                )
                let spec = await self.approvalContractSpec(
                    toolName: toolName,
                    route: route,
                    isElevated: isElevated
                )
                await lifecycleEmitter.emit(
                    .toolApprovalRequired(
                        ToolApprovalRequiredInfo(
                            iteration: iteration,
                            modelID: modelID,
                            toolName: toolName,
                            toolCallID: toolCallID,
                            route: route,
                            title: spec.title,
                            description: spec.description,
                            severity: spec.severity,
                            timeoutMs: spec.timeoutMs,
                            timeoutBehavior: spec.timeoutBehavior.rawValue,
                            resolutionKind: ToolApprovalResolutionKind.runtimeAuto.rawValue,
                            presentation: spec.presentation,
                            source: "runtime.toolDispatch"
                        )
                    ),
                    conversationID: conversationID,
                    runID: runID
                )
                let resolution: ToolApprovalResolution
                do {
                    resolution = try await self.waitForToolApprovalResolution(
                        conversationID: conversationID,
                        runID: runID,
                        toolName: toolName,
                        route: route
                    )
                } catch {
                    return .denied(
                        AgentLoopToolDispatch.toolResultMessage(
                            toolCallId: toolCallID,
                            content: "Tool dispatch denied: denied-cancelled."
                        )
                    )
                }
                if resolution.kind == .timeoutDefault {
                    let approvalState: RuntimeLifecycleApprovalState = resolution.status == .approved ? .approved : .denied
                    await lifecycleEmitter.emit(
                        .toolApprovalResolved(
                            ToolApprovalResolvedInfo(
                                iteration: iteration,
                                modelID: modelID,
                                toolName: toolName,
                                toolCallID: toolCallID,
                                approvalState: approvalState,
                                policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                                approvalSource: resolution.source,
                                approvalReason: resolution.reason,
                                route: route,
                                title: spec.title,
                                description: spec.description,
                                severity: spec.severity,
                                timeoutMs: spec.timeoutMs,
                                timeoutBehavior: spec.timeoutBehavior.rawValue,
                                resolutionKind: resolution.kind.rawValue,
                                presentation: spec.presentation,
                                source: "runtime.approvalTimeout"
                            )
                        ),
                        conversationID: conversationID,
                        runID: runID
                    )
                }
                switch resolution.status {
                case .approved:
                    let approvalConfig = await self.configurationApplyingToolApprovals(
                        configuration,
                        conversationID: conversationID,
                        runID: runID
                    )
                    guard let conversation = await self.runtimeConversation(id: conversationID) else {
                        return .denied(
                            AgentLoopToolDispatch.toolResultMessage(
                                toolCallId: toolCallID,
                                content: "Tool dispatch denied: conversation not found."
                            )
                        )
                    }
                    let entries = await self.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
                    let refreshedSnapshot = await self.buildToolTurnPolicySnapshot(
                        allEntries: entries,
                        conversation: conversation,
                        configuration: approvalConfig
                    )
                    return await AgentLoopToolDispatch.dispatch(
                        call: call,
                        conversationID: conversationID,
                        runID: runID,
                        orchestrator: orchestrator,
                        snapshot: refreshedSnapshot,
                        configuration: approvalConfig,
                        conversation: conversation,
                        gateway: DefaultToolSystemGateway(),
                        parentLookup: { [deps = self.deps] id in
                            await deps.persistenceDomain.modelConversation(id: id)
                        },
                        spawnService: self.subAgentSpawnServiceForRuntime()
                    )
                case .denied:
                    return .denied(
                        AgentLoopToolDispatch.toolResultMessage(
                            toolCallId: toolCallID,
                            content: "Tool dispatch denied."
                        )
                    )
                case .pending:
                    return .denied(
                        AgentLoopToolDispatch.toolResultMessage(
                            toolCallId: toolCallID,
                            content: "Tool dispatch denied: approval pending."
                        )
                    )
                }
            },
            dispatchApprovalFn: { [self] toolName, toolCallID, snapshot, conversationID, runID, iteration, modelID, lifecycleEmitter in
                let evaluation = snapshot.availabilitySnapshots.first(where: { $0.entry.name == toolName })
                let route = evaluation?.decision.approvalRoute ?? .user
                let isElevated = evaluation?.decision.isElevated ?? false
                _ = await self.registerPendingToolApproval(
                    conversationID: conversationID,
                    runID: runID,
                    toolName: toolName,
                    route: route,
                    isElevated: isElevated
                )
                let spec = await self.approvalContractSpec(
                    toolName: toolName,
                    route: route,
                    isElevated: isElevated
                )
                await lifecycleEmitter.emit(
                    .toolApprovalRequired(
                        ToolApprovalRequiredInfo(
                            iteration: iteration,
                            modelID: modelID,
                            toolName: toolName,
                            toolCallID: toolCallID,
                            route: route,
                            title: spec.title,
                            description: spec.description,
                            severity: spec.severity,
                            timeoutMs: spec.timeoutMs,
                            timeoutBehavior: spec.timeoutBehavior.rawValue,
                            resolutionKind: ToolApprovalResolutionKind.runtimeAuto.rawValue,
                            presentation: spec.presentation,
                            source: "runtime.toolDispatch"
                        )
                    ),
                    conversationID: conversationID,
                    runID: runID
                )
            },
            isHaltingFn: { [self] toolName, entries in
                await self.runtimeIsHaltingToolCall(toolName: toolName, effectiveEntries: entries)
            }
        )
        let conversationPort = SessionRuntimeConversationPort(
            conversationFn: { [self] id in await self.runtimeConversation(id: id) },
            appendFn: { [self] (message: Message, conversationID: UUID, runID: UUID?) in
                // TurnLoop is the sole transcript writer during a run; optimistic tail checks are intentionally skipped.
                _ = try await self.messaging.saveMessageToCache(
                    message,
                    for: conversationID,
                    expectedPreviousTailHarnessMessageID: nil,
                    transcriptRunID: runID
                )
                guard let conversation = await self.runtimeConversation(id: conversationID) else { return }
                await self.messaging.refreshProjectedConversationMessages(
                    conversationID: conversationID,
                    baseMessagesOverride: conversation.messages
                )
                await self.messaging.syncProjectionFromRegistry(conversationID: conversationID)
            },
            markerFn: { [self] (conversationID: UUID, runID: UUID?, iteration: Int) in
                guard let runID else { return }
                await self.subAgentSpawnServiceForRuntime()?.cancelActiveInvocationsForParent(
                    parentConversationID: conversationID
                )
                do {
                    try await self.routingPersistRunLifecycleTranscriptMarker(
                        conversationID: conversationID,
                        payload: RunLifecycleTranscriptMarkerPayload(
                            kind: .run_cancelled,
                            runId: runID,
                            reason: "task_cancelled_iter_\(iteration)",
                            terminalReason: ConversationRunTerminalReason(
                                category: .externalCancellation,
                                detail: "task_cancelled"
                            )
                        )
                    )
                } catch {
                    self.deps.logger?.warning("[AgentLoop] run_cancelled marker failed: \(error)")
                }
            },
            rollbackFn: { [self] messageID, conversationID in
                await self.rollbackLatestStalledAssistantTurn(
                    conversationID: conversationID,
                    assistantMessageID: messageID
                )
            },
            stampFinishReasonFn: { [self] messageID, conversationID, finishReason in
                await self.stampAssistantFinishReason(
                    conversationID: conversationID,
                    messageID: messageID,
                    finishReason: finishReason
                )
            },
            stopRequestedFn: { [self] conversationID in
                await self.turnLoopStopRequested(for: conversationID)
            }
        )
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { [self] conversationID, userQuery in
                guard let memoryService = (self.deps.contextEngine as? DefaultContextEngine)?.memoryService,
                      let session = await memoryService.sessionContext(for: conversationID) else {
                    return nil
                }
                return await memoryService.activeRecallSummary(session: session, userQuery: userQuery)
            },
            prefetchFn: { [self] conversationID, userQuery in
                guard let memoryService = (self.deps.contextEngine as? DefaultContextEngine)?.memoryService,
                      let session = await memoryService.sessionContext(for: conversationID) else {
                    return
                }
                await memoryService.prefetchSituationalRecall(session: session, userQuery: userQuery)
            }
        )
        return AgentLoopPorts(
            model: modelPort,
            context: contextPort,
            tools: toolPort,
            conversation: conversationPort,
            memory: memoryPort,
            agentHarness: deps.agentHarness,
            contextCompaction: deps.conversationTransformConfiguration.contextCompaction,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
    }
}

/// Per-`makeAgentLoopPorts()` cache; a single turn accesses this sequentially from one loop task.
private final class BoundModelIDCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UUID?

    var value: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}
