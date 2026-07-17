import Foundation
import SwiftAgentKit

/// Local runtime contract for tool dispatch policy handoff into SwiftAgentKit.
struct AgentRuntimeToolDispatchContract: Sendable, Equatable {
    /// Host-level default. SwiftAgentKit still falls back to serial when metadata is unknown or mutating.
    var parallelDispatchEnabled: Bool
    /// Optional planner mode for batch dispatch (`serial`, `allParallel`, `mixedDeterministic`).
    var dispatchPlannerMode: ToolPolicyConfiguration.DispatchPlannerMode?
    /// Optional timeout for pending tool handles accepted by the orchestrator.
    var pendingToolTimeoutSeconds: TimeInterval?
    /// Wall-clock bound for each tool dispatch (seconds).
    var toolCallTimeoutSeconds: TimeInterval
    /// Heartbeat interval for in-flight tool watchdog logs (seconds).
    var toolCallWatchdogIntervalSeconds: TimeInterval
    /// Recovery policy after a tool execution timeout.
    var onToolTimeout: ToolPolicyConfiguration.OnToolTimeoutPolicy
    /// When true, attempt a single MCP client reconnect after tool timeout (requires Kit K9).
    var mcpReconnectOnToolTimeout: Bool

    static let conservativeDefault = AgentRuntimeToolDispatchContract(
        parallelDispatchEnabled: false,
        dispatchPlannerMode: nil,
        pendingToolTimeoutSeconds: nil,
        toolCallTimeoutSeconds: 300,
        toolCallWatchdogIntervalSeconds: 20,
        onToolTimeout: .continue,
        mcpReconnectOnToolTimeout: false
    )
}

/// Local runtime contract for pending completion ingress deduplication and replay safety.
struct AgentRuntimePendingCompletionEnvelope: Sendable, Equatable {
    let completion: PendingToolCompletion
    let receivedAt: Date

    init(completion: PendingToolCompletion, receivedAt: Date = Date()) {
        self.completion = completion
        self.receivedAt = receivedAt
    }
}
