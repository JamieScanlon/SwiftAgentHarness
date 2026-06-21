import Foundation
import SwiftAgentKit

/// HarnessRuntimeSession-backed runtime coordinator that owns one canonical runTurn entrypoint.
struct AgentRuntimeCoordinator: AgentRuntimeExecuting {
    private let runCore: @Sendable (AgentRuntimeRunContext, AgentRuntimeLifecycleEmitter) async throws -> ConversationRunTerminalReason

    init(runtime: any AgentRuntimeCoordinatorServicing) {
        self.runCore = { context, lifecycleEmitter in
            let ports = await runtime.makeAgentLoopPorts()
            let loop = TurnLoop(ports: ports) { partial, conversationID, runID in
                await runtime.publishAgentLoopDelta(partial, conversationID: conversationID, runID: runID)
            }
            let terminalReason = try await loop.run(
                conversationID: context.conversationID,
                runID: context.runID,
                anchorUserMessageID: context.turnLoopAnchorUserMessageID,
                configuration: context.configuration,
                orchestrator: context.orchestrator,
                lifecycleEmitter: lifecycleEmitter
            )
            await runtime.afterTurnContextEngineLifecycle(
                conversationID: context.conversationID,
                runID: context.runID,
                terminalReason: terminalReason,
                anchorUserMessageID: context.turnLoopAnchorUserMessageID
            )
            return terminalReason
        }
    }

    init(
        runCore: @escaping @Sendable (AgentRuntimeRunContext, AgentRuntimeLifecycleEmitter) async throws -> ConversationRunTerminalReason
    ) {
        self.runCore = runCore
    }

    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult {
        let lifecycleEmitter = context.lifecycleEmitter()
        do {
            let reason = try await runCore(context, lifecycleEmitter)
            if reason.category == .externalCancellation {
                return .cancelled(reason: reason)
            }
            return .completed(reason: reason)
        } catch is CancellationError {
            return .cancelled(
                reason: ConversationRunTerminalReason(
                    category: .externalCancellation,
                    detail: "task_cancelled"
                )
            )
        } catch {
            return Self.failureResult(for: error)
        }
    }

    static func failureResult(for error: Error) -> AgentRuntimeRunResult {
        let policy = AgentRuntimeErrorPolicy.outcome(for: error)
        if policy.handling == .continueLoop {
            return .completed(
                reason: ConversationRunTerminalReason(
                    category: .naturalStop,
                    detail: "tool_error_continued"
                )
            )
        }
        return .failed(policy: policy, error: error)
    }
}
