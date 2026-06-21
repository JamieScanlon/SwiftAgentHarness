import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

protocol AgentRuntimeCoordinatorServicing: Actor {
    func afterTurnContextEngineLifecycle(
        conversationID: UUID,
        runID: UUID?,
        terminalReason: ConversationRunTerminalReason?,
        anchorUserMessageID: UUID?
    ) async
    func makeAgentLoopPorts() async -> AgentLoopPorts
    func publishAgentLoopDelta(
        _ partial: ChatStreamingPartial,
        conversationID: UUID,
        runID: UUID?
    ) async
}

typealias AgentRuntimeExecutorFactory = @Sendable (_ runtime: any AgentRuntimeCoordinatorServicing) -> any AgentRuntimeExecuting

enum AgentRuntimeExecutorFactories {
    static let `default`: AgentRuntimeExecutorFactory = { runtime in
        AgentRuntimeCoordinator(runtime: runtime)
    }
}

/// Canonical runtime boundary for one turn execution.
protocol AgentRuntimeExecuting: Sendable {
    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult
    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution
}

/// Stateless per-invocation runtime input.
struct AgentRuntimeTurnConfiguration: Sendable {
    var enableTools: Bool = true
    var enableAgents: Bool = true
    var allowEscalatedTools: Bool = false
    var preApprovedToolNames: Set<String> = []
    var expectedPreviousTailHarnessMessageID: UUID? = nil
    var inputTrustRaw: String? = nil
    var resolvedInputTrustClass: TrustPolicyClass? = nil
    var ephemeralSystemReminder: String? = nil
    var originSurface: String? = nil
    var originSenderID: String? = nil
}

struct AgentRuntimeRunContext {
    let conversationID: UUID
    let conversationScope: ConversationScope
    let runID: UUID?
    let turnLoopAnchorUserMessageID: UUID?
    let configuration: AgentRuntimeTurnConfiguration
    let orchestrator: SwiftAgentKitOrchestrator
    /// Optional fan-out sink for runtime lifecycle payloads produced during this invocation.
    let runtimeLifecyclePublish: (@Sendable (RuntimeLifecycleEventPayload) async -> Void)?
    /// Optional explicit emitter override used by executeTurn wrappers.
    var lifecycleEmitterOverride: AgentRuntimeLifecycleEmitter?

    func withLifecycleEmitter(_ emitter: AgentRuntimeLifecycleEmitter) -> AgentRuntimeRunContext {
        var context = self
        context.lifecycleEmitterOverride = emitter
        return context
    }

    func lifecycleEmitter() -> AgentRuntimeLifecycleEmitter {
        if let lifecycleEmitterOverride {
            return lifecycleEmitterOverride
        }
        return AgentRuntimeLifecycleEmitter { _, payload in
            if let runtimeLifecyclePublish {
                await runtimeLifecyclePublish(payload)
            }
        }
    }
}

/// Unified runtime execution primitive: one event stream + one terminal result task.
struct AgentRuntimeTurnExecution {
    let events: AsyncStream<RuntimeLifecycleEventPayload>
    let result: Task<AgentRuntimeRunResult, Never>
}

enum AgentRuntimeTerminalState: Equatable {
    case completed
    case cancelled
    case failed
}

enum AgentRuntimeErrorClass: String {
    case modelOrPool
    case tool
    case runtime
    case cancellation
}

/// Marker for runtime-surface tool failures that should not hard-fail the whole turn.
protocol AgentRuntimeToolError: Error {}

enum AgentRuntimeErrorHandlingPolicy: String {
    case continueLoop
    case failTurn
}

struct AgentRuntimeErrorPolicyOutcome {
    let errorClass: AgentRuntimeErrorClass
    let handling: AgentRuntimeErrorHandlingPolicy
}

struct AgentRuntimeRunResult {
    let terminalState: AgentRuntimeTerminalState
    let terminalReason: ConversationRunTerminalReason?
    let errorPolicy: AgentRuntimeErrorPolicyOutcome?
    let underlyingError: Error?

    static func completed(reason: ConversationRunTerminalReason) -> Self {
        .init(terminalState: .completed, terminalReason: reason, errorPolicy: nil, underlyingError: nil)
    }

    static func cancelled(reason: ConversationRunTerminalReason? = nil, error: Error? = nil) -> Self {
        .init(
            terminalState: .cancelled,
            terminalReason: reason ?? ConversationRunTerminalReason(category: .externalCancellation),
            errorPolicy: AgentRuntimeErrorPolicyOutcome(
                errorClass: .cancellation,
                handling: .failTurn
            ),
            underlyingError: error
        )
    }

    static func failed(policy: AgentRuntimeErrorPolicyOutcome, error: Error) -> Self {
        .init(
            terminalState: .failed,
            terminalReason: ConversationRunTerminalReason(
                category: .failure,
                detail: error.localizedDescription
            ),
            errorPolicy: policy,
            underlyingError: error
        )
    }
}

enum AgentRuntimeErrorPolicy {
    static func classify(_ error: Error) -> AgentRuntimeErrorClass {
        if error is CancellationError {
            return .cancellation
        }
        if error is any AgentRuntimeToolError {
            return .tool
        }
        if error is LLMError || error is ModelPoolError {
            return .modelOrPool
        }
        if error is OrchestratorError {
            // Orchestrator-level throw means the model/pool path failed hard.
            return .modelOrPool
        }
        return .runtime
    }

    static func outcome(for errorClass: AgentRuntimeErrorClass) -> AgentRuntimeErrorPolicyOutcome {
        switch errorClass {
        case .tool:
            return AgentRuntimeErrorPolicyOutcome(errorClass: .tool, handling: .continueLoop)
        case .modelOrPool, .runtime, .cancellation:
            return AgentRuntimeErrorPolicyOutcome(errorClass: errorClass, handling: .failTurn)
        }
    }

    static func outcome(for error: Error) -> AgentRuntimeErrorPolicyOutcome {
        outcome(for: classify(error))
    }
}

extension AgentRuntimeExecuting {
    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution {
        let (events, continuation) = AsyncStream.makeStream(
            of: RuntimeLifecycleEventPayload.self,
            bufferingPolicy: .unbounded
        )
        let result = Task {
            let emitter = AgentRuntimeLifecycleEmitter { _, payload in
                continuation.yield(payload)
            }
            await emitter.emit(
                .turnStarted,
                conversationID: context.conversationID,
                runID: context.runID
            )
            let runtimeResult = await runTurn(context.withLifecycleEmitter(emitter))
            await emitter.emit(
                .turnTerminal(
                    runtimeResult.terminalReason
                        ?? ConversationRunTerminalReason(category: .naturalStop)
                ),
                conversationID: context.conversationID,
                runID: context.runID
            )
            continuation.finish()
            return runtimeResult
        }
        return AgentRuntimeTurnExecution(events: events, result: result)
    }
}
