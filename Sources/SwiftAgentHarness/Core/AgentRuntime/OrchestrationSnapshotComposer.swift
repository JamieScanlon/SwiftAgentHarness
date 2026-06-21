//
//  Maps SwiftAgentKit orchestration + plan snapshot into ``ConversationOrchestrationState`` (extracted from HarnessRuntimeSession).
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

/// Result of building a UI/server orchestration snapshot; optional **phase patch** when in-memory ``ModelConversation`` should be synced.
struct OrchestrationSnapshotPhasePatch: Sendable {
    var agenticPhase: ConversationAgenticPhase
    var llmRequestPhase: ConversationLLMRequestPhase?
}

enum OrchestrationSnapshotComposer {
    static func mapConversationLLMRuntime(_ state: LLMRuntimeState) -> (ConversationLLMRuntimePhase, String?) {
        switch state {
        case .idle(.ready):
            return (.idleReady, nil)
        case .idle(.completed):
            return (.idleCompleted, nil)
        case .generating(.reasoning):
            return (.generatingReasoning, nil)
        case .generating(.responding):
            return (.generatingResponding, nil)
        case .failed(let msg):
            return (.failed, msg)
        }
    }

    static func planSnapshotHasBlockedTasks(for conversationID: UUID) -> Bool {
        guard let text = AgentPlanStore.readPlanText(for: conversationID) else { return false }
        return AgentPlanParser.hasBlockedTaskLine(in: text)
    }

    static func planSnapshotAllTasksComplete(for conversationID: UUID) -> Bool {
        guard let text = AgentPlanStore.readPlanText(for: conversationID) else { return false }
        return AgentPlanParser.isPlanFullyComplete(in: text)
    }

    /// When ``ModelConversation/state`` is idle, only strip stale agentic/request phases if the LLM runtime snapshot is also idle.
    static func shouldStripOrchestrationRequestAgenticWhileConversationIdle(
        llmRuntimePhase: ConversationLLMRuntimePhase
    ) -> Bool {
        switch llmRuntimePhase {
        case .idleReady, .idleCompleted:
            return true
        case .generatingReasoning, .generatingResponding, .failed:
            return false
        }
    }

    /// Build wire snapshot; when `patch` is non-nil, caller should merge phases into the live ``ModelConversation`` row.
    static func buildSnapshot(
        conversation: ModelConversation,
        orchestrator: SwiftAgentKitOrchestrator?,
        lastContextLimitTokens: Int?,
        lastRemainingContextTokens: Int?,
        lastPromptTokens: Int?,
        currentRunID: UUID?,
        forceStreamingPhases: Bool = false,
        logger: Logger?
    ) async -> (snapshot: ConversationOrchestrationState, patch: OrchestrationSnapshotPhasePatch?) {
        let planBlocked = planSnapshotHasBlockedTasks(for: conversation.id)
        let planComplete = planSnapshotAllTasksComplete(for: conversation.id)
        let contextLimit = lastContextLimitTokens ?? conversation.model.maxContextLength
        guard let orchestrator else {
            let agentic = conversation.state == .idle ? ConversationAgenticPhase.idle : conversation.agenticPhase
            let request: ConversationLLMRequestPhase? =
                if forceStreamingPhases {
                    .streaming
                } else if conversation.state == .idle {
                    .idle
                } else {
                    conversation.llmRequestPhase
                }
            let llmPhase: ConversationLLMRuntimePhase = forceStreamingPhases ? .generatingResponding : .idleReady
            return (
                ConversationOrchestrationState(
                    llmRuntimePhase: llmPhase,
                    llmRuntimeFailureDetail: nil,
                    agenticPhase: agentic,
                    llmRequestPhase: request,
                    contextLimitTokens: contextLimit,
                    remainingContextTokens: lastRemainingContextTokens,
                    promptTokens: lastPromptTokens,
                    planHasBlockedTasks: planBlocked,
                    planAllTasksComplete: planComplete,
                    harness: nil,
                    currentRunID: currentRunID
                ),
                nil
            )
        }

        let sak = await orchestrator.currentOrchestrationSnapshot()
        let (observedLLMPhase, llmDetail) = mapConversationLLMRuntime(sak.llmRuntime)
        var agenticPhase = OrchestrationStateMapping.pickAgenticPhase(
            from: sak.agenticLoopStates,
            fallback: conversation.agenticPhase
        )
        var requestPhase = OrchestrationStateMapping.pickRequestPhase(
            from: sak.perRequestStates,
            fallback: conversation.llmRequestPhase
        )
        if forceStreamingPhases {
            requestPhase = .streaming
        }
        let llmPhase = forceStreamingPhases
            ? .generatingResponding
            : inferredLLMRuntimePhase(
                observed: observedLLMPhase,
                requestPhase: requestPhase,
                agenticPhase: agenticPhase
            )
        let inferredAgentic = inferredAgenticPhase(
            observed: agenticPhase,
            llmRuntimePhase: llmPhase,
            requestPhase: requestPhase
        )
        if inferredAgentic != agenticPhase {
            logger?.debug(
                "[OrchestrationSnapshotComposer] inferred agentic phase observed=\(agenticPhase.rawValue) inferred=\(inferredAgentic.rawValue) llm=\(llmPhase.rawValue) request=\(requestPhase?.rawValue ?? "nil")"
            )
            agenticPhase = inferredAgentic
        }

        let stripAuxiliaryWhileConvIdle =
            !forceStreamingPhases &&
            conversation.state == .idle
            && shouldStripOrchestrationRequestAgenticWhileConversationIdle(llmRuntimePhase: llmPhase)

        var patch: OrchestrationSnapshotPhasePatch?
        if stripAuxiliaryWhileConvIdle {
            if agenticPhase != ConversationAgenticPhase.idle || requestPhase != ConversationLLMRequestPhase.idle {
                logger?.debug(
                    "[OrchestrationSnapshotComposer] strip: conv.state=idle → idle request/agentic (was agentic=\(agenticPhase.rawValue) request=\(requestPhase.map(\.rawValue) ?? "nil"))"
                )
            }
            agenticPhase = ConversationAgenticPhase.idle
            requestPhase = ConversationLLMRequestPhase.idle
            if conversation.agenticPhase != ConversationAgenticPhase.idle || conversation.llmRequestPhase != ConversationLLMRequestPhase.idle {
                patch = OrchestrationSnapshotPhasePatch(agenticPhase: .idle, llmRequestPhase: .idle)
            }
        } else if conversation.agenticPhase != agenticPhase || conversation.llmRequestPhase != requestPhase {
            patch = OrchestrationSnapshotPhasePatch(agenticPhase: agenticPhase, llmRequestPhase: requestPhase)
        }

        let harness: HarnessOrchestrationSupplement?
        if HarnessTelemetryWireConfig.enabled {
            harness = HarnessOrchestrationSupplementBuilder.build(
                agenticLoopStates: sak.agenticLoopStates,
                perRequestStates: sak.perRequestStates
            )
        } else {
            harness = nil
        }

        let snapshot = ConversationOrchestrationState(
            llmRuntimePhase: llmPhase,
            llmRuntimeFailureDetail: llmDetail,
            agenticPhase: agenticPhase,
            llmRequestPhase: requestPhase,
            contextLimitTokens: contextLimit,
            remainingContextTokens: lastRemainingContextTokens,
            promptTokens: lastPromptTokens,
            planHasBlockedTasks: planBlocked,
            planAllTasksComplete: planComplete,
            harness: harness,
            currentRunID: currentRunID
        )
        return (snapshot, patch)
    }

    /// Runtime LLM phase from SwiftAgentKit can lag during high-frequency streaming updates.
    /// If a request is clearly in flight, prefer a generating runtime phase for status/UI parity.
    static func inferredLLMRuntimePhase(
        observed: ConversationLLMRuntimePhase,
        requestPhase: ConversationLLMRequestPhase?,
        agenticPhase: ConversationAgenticPhase
    ) -> ConversationLLMRuntimePhase {
        guard observed == .idleReady || observed == .idleCompleted else { return observed }
        guard let requestPhase else {
            if agenticPhase == .llmCall {
                return .generatingResponding
            }
            return observed
        }
        switch requestPhase {
        case .active, .generating, .streaming:
            return .generatingResponding
        case .queued where agenticPhase == .llmCall:
            return .generatingResponding
        case .queued, .completed, .failed, .cancelled, .idle:
            return observed
        }
    }

    static func inferredAgenticPhase(
        observed: ConversationAgenticPhase,
        llmRuntimePhase: ConversationLLMRuntimePhase,
        requestPhase: ConversationLLMRequestPhase?
    ) -> ConversationAgenticPhase {
        guard llmRuntimePhase == .idleReady || llmRuntimePhase == .idleCompleted else { return observed }
        switch (observed, requestPhase) {
        case (.llmGenerationCompleted, .queued):
            return .waitingForToolExecution
        case (.llmGenerationCompleted, .active),
            (.started, .active):
            return .executingTools
        default:
            return observed
        }
    }
}
