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

public enum AgentRuntimeExecutorFactories {
    public typealias Factory = @Sendable (_ runtime: AgentRuntimeSessionService) -> AgentRuntimeCoordinator

    public static let `default`: Factory = { runtime in
        AgentRuntimeCoordinator(runtime: runtime)
    }

    static func adapt(_ factory: @escaping Factory) -> AgentRuntimeExecutorFactory {
        { runtime in
            guard let session = runtime as? AgentRuntimeSessionService else {
                preconditionFailure("AgentRuntimeExecutorFactories requires AgentRuntimeSessionService runtime")
            }
            return factory(session)
        }
    }

    static var defaultInternal: AgentRuntimeExecutorFactory {
        adapt(`default`)
    }
}

/// Canonical runtime boundary for one turn execution.
protocol AgentRuntimeExecuting: Sendable {
    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult
    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution
}

/// Stateless per-invocation runtime input.
public struct AgentRuntimeTurnConfiguration: Sendable {
    public var enableTools: Bool
    public var enableAgents: Bool
    public var allowEscalatedTools: Bool
    public var preApprovedToolNames: Set<String>
    public var expectedPreviousTailHarnessMessageID: UUID?
    public var inputTrustRaw: String?
    public var resolvedInputTrustClass: TrustPolicyClass?
    public var ephemeralSystemReminder: String?
    public var originSurface: String?
    public var originSenderID: String?
    public var turnThinkingOverride: ThinkingConfig?
    public var turnModelSlug: String?

    public init(
        enableTools: Bool = true,
        enableAgents: Bool = true,
        allowEscalatedTools: Bool = false,
        preApprovedToolNames: Set<String> = [],
        expectedPreviousTailHarnessMessageID: UUID? = nil,
        inputTrustRaw: String? = nil,
        resolvedInputTrustClass: TrustPolicyClass? = nil,
        ephemeralSystemReminder: String? = nil,
        originSurface: String? = nil,
        originSenderID: String? = nil,
        turnThinkingOverride: ThinkingConfig? = nil,
        turnModelSlug: String? = nil
    ) {
        self.enableTools = enableTools
        self.enableAgents = enableAgents
        self.allowEscalatedTools = allowEscalatedTools
        self.preApprovedToolNames = preApprovedToolNames
        self.expectedPreviousTailHarnessMessageID = expectedPreviousTailHarnessMessageID
        self.inputTrustRaw = inputTrustRaw
        self.resolvedInputTrustClass = resolvedInputTrustClass
        self.ephemeralSystemReminder = ephemeralSystemReminder
        self.originSurface = originSurface
        self.originSenderID = originSenderID
        self.turnThinkingOverride = turnThinkingOverride
        self.turnModelSlug = turnModelSlug
    }
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
