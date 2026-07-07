import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

extension AgentRuntimeSessionService {
    func publishConversationTopicIfBound(
        conversationID: UUID,
        payload: ConversationTopicEventPayload
    ) async {
        await topics.publishConversationTopicEventIfConfigured(
            conversationID: conversationID,
            payload: payload
        )
    }

    func publishRuntimeLifecycleEventIfBound(_ payload: RuntimeLifecycleEventPayload) async {
        await topics.publishRuntimeLifecycleEvent(payload)
    }

    func stripRunTailIfBound(conversationID: UUID, anchorUserMessageID: UUID) async {
        await stripRunTail(conversationID: conversationID, anchorUserMessageID: anchorUserMessageID)
    }

    func applyStreamingUserCancellationIfBound(conversationID: UUID) async {
        await messaging.applyStreamingUserCancellation(conversationID: conversationID)
    }

    func applySendFailureIfBound(_ error: Error, conversationID: UUID) async {
        await messaging.applySendFailure(error, conversationID: conversationID)
    }

    func emitOrchestrationStateIfBound(
        swiftAgentKitGeneration: UInt64? = nil,
        preferredConversationID: UUID
    ) async {
        await emitOrchestrationStateFromLiveSources(
            swiftAgentKitGeneration: swiftAgentKitGeneration,
            preferredConversationID: preferredConversationID
        )
    }

    func startStreamingOrchestrationTask(
        sendingConversationID: UUID,
        turnLoopAnchorUserMessageID: UUID?,
        configuration: Configuration,
        orchestrator: SwiftAgentKitOrchestrator
    ) async {
        let logger = deps.logger
        clearTurnLoopStopRequest(for: sendingConversationID)
        await cancelInFlightStreamingGenerationOnly(for: sendingConversationID)
        var runtimeLifecycle = await currentLifecycleSnapshot(for: sendingConversationID)
        runtimeLifecycle.streamingGenerationSequence += 1
        runtimeLifecycle.isContentStreamingActive = false
        let generationToken = runtimeLifecycle.streamingGenerationSequence
        let capturedRunID = runtimeLifecycle.currentStreamingRunID
        if let capturedRunID {
            setPendingTerminalReason(nil, conversationID: sendingConversationID, runID: capturedRunID)
        }
        runtimeLifecycle.activeAnchorUserMessageID = turnLoopAnchorUserMessageID
        runtimeLifecycle.activeStreamingConversationID = sendingConversationID
        let stagedStreamingGenerationSequence = runtimeLifecycle.streamingGenerationSequence
        let stagedContentStreamingActive = runtimeLifecycle.isContentStreamingActive
        let stagedActiveAnchorUserMessageID = runtimeLifecycle.activeAnchorUserMessageID
        let stagedActiveStreamingConversationID = runtimeLifecycle.activeStreamingConversationID
        let generationTask: Task<Void, Error> = Task { [weak self, logger, orchestrator, sendingConversationID, turnLoopAnchorUserMessageID, configuration, capturedRunID, generationToken] in
            guard let self else { return }
            let streamTransportAdapter = RuntimeTurnStreamTransportAdapter(logger: logger) { [self] payload in
                await self.publishRuntimeLifecycleEventIfBound(payload)
            }
            let runtimeExecutorFactory = deps.runtimeExecutorFactory
            let runtimeExecutor = runtimeExecutorFactory(self)
            let turnConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: configuration)
            await registerActiveTurnConfiguration(
                conversationID: sendingConversationID,
                runID: capturedRunID,
                configuration: turnConfiguration
            )
            defer {
                // Backstop if the generation task exits abruptly before the explicit clear below.
                Task { await self.clearActiveTurnConfiguration(runID: capturedRunID) }
                Task { await self.finishAgentLoopPartialStream(runID: capturedRunID) }
            }
            let runtimeExecution: AgentRuntimeTurnExecution
            if let conversation = await self.runtimeConversation(id: sendingConversationID) {
                let scope = conversation.conversationScope()
                runtimeExecution = await ConversationScope.withCurrent(scope) {
                    runtimeExecutor.executeTurn(
                        AgentRuntimeRunContext(
                            conversationID: sendingConversationID,
                            conversationScope: scope,
                            runID: capturedRunID,
                            turnLoopAnchorUserMessageID: turnLoopAnchorUserMessageID,
                            configuration: turnConfiguration,
                            orchestrator: orchestrator,
                            runtimeLifecyclePublish: nil,
                            lifecycleEmitterOverride: nil
                        )
                    )
                }
            } else {
                let scope = ConversationScope(
                    selfID: sendingConversationID,
                    parentID: nil,
                    rootID: sendingConversationID,
                    lineageKind: .root,
                    origin: .user
                )
                runtimeExecution = runtimeExecutor.executeTurn(
                    AgentRuntimeRunContext(
                        conversationID: sendingConversationID,
                        conversationScope: scope,
                        runID: capturedRunID,
                        turnLoopAnchorUserMessageID: turnLoopAnchorUserMessageID,
                        configuration: turnConfiguration,
                        orchestrator: orchestrator,
                        runtimeLifecyclePublish: nil,
                        lifecycleEmitterOverride: nil
                    )
                )
            }
            let consumeRuntimeEventsTask = Task {
                for await event in runtimeExecution.events {
                    await streamTransportAdapter.consume(event)
                }
                await streamTransportAdapter.publishToolUsageSummaryIfNeeded(
                    conversationID: sendingConversationID,
                    runID: capturedRunID
                )
            }
            let runtimeResult = await withTaskCancellationHandler {
                await runtimeExecution.result.value
            } onCancel: {
                runtimeExecution.result.cancel()
            }
            _ = await consumeRuntimeEventsTask.value
            let activeAnchor = turnLoopAnchorUserMessageID
            let terminal = await RuntimeTurnTerminalHandler.resolve(
                result: runtimeResult,
                conversationID: sendingConversationID,
                runID: capturedRunID,
                activeAnchorUserMessageID: activeAnchor,
                setPendingTerminalReason: { [self] conversationID, runID, reason in
                    await self.setPendingTerminalReason(reason, conversationID: conversationID, runID: runID)
                },
                stripRunTailAfterAnchorIfNeeded: { [self] conversationID, anchorID in
                    await self.stripRunTailIfBound(
                        conversationID: conversationID,
                        anchorUserMessageID: anchorID
                    )
                },
                applyStreamingUserCancellation: { [self] conversationID in
                    await self.applyStreamingUserCancellationIfBound(conversationID: conversationID)
                },
                applySendFailure: { [self] error in
                    await self.applySendFailureIfBound(error, conversationID: sendingConversationID)
                },
                logInfo: { message in
                    logger?.info("\(message)")
                },
                logError: { message in
                    logger?.error("\(message)")
                }
            )
            await finishAgentLoopPartialStream(runID: capturedRunID)
            await markStreamingGenerationCompleteIfCurrent(
                token: generationToken,
                terminalStatus: terminal.status,
                terminalReason: runtimeResult.terminalReason,
                markerKind: terminal.markerKind,
                conversationID: sendingConversationID,
                runID: capturedRunID
            )
            await emitOrchestrationStateIfBound(
                swiftAgentKitGeneration: nil,
                preferredConversationID: sendingConversationID
            )
            await finishOrchestrationStateStream()
            // Clear pending terminal reason after stream is closed so no other emission
            // can race and consume it before the authoritative terminal snapshot above.
            if let capturedRunID {
                await self.setPendingTerminalReason(nil, conversationID: sendingConversationID, runID: capturedRunID)
            }
            // Primary turn-config cleanup on normal generation completion (defer Task is backstop only).
            await clearActiveTurnConfiguration(runID: capturedRunID)
            if let runID = capturedRunID {
                await self.releaseRunOrchestrator(runID: runID)
            }
        }
        runtimeLifecycle.generationTask = generationTask
        await updateLifecycle(for: sendingConversationID) { lifecycle in
            lifecycle.streamingGenerationSequence = stagedStreamingGenerationSequence
            lifecycle.isContentStreamingActive = stagedContentStreamingActive
            lifecycle.activeAnchorUserMessageID = stagedActiveAnchorUserMessageID
            lifecycle.activeStreamingConversationID = stagedActiveStreamingConversationID
            lifecycle.generationTask = generationTask
        }
    }

    func cancelInFlightStreamingGenerationOnly(for conversationID: UUID? = nil) async {
        if let conversationID {
            await updateLifecycle(for: conversationID) { lifecycle in
                lifecycle.generationTask?.cancel()
                lifecycle.generationTask = nil
            }
        } else {
            await updateLifecycle { lifecycle in
                lifecycle.generationTask?.cancel()
                lifecycle.generationTask = nil
            }
        }
    }
}
