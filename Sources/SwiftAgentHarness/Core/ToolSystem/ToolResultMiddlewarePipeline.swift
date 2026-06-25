import Foundation
import SwiftAgentKit

enum ToolResultMiddlewareStage: String, Sendable {
    case runtimeDelivery
    case persistence
}

/// Public host-facing registration for runtime-delivery tool-result middleware. Mounted via
/// ``OrchestratorRuntimeService/registerAgentToolResultMiddleware(_:)``, this is the spec's
/// runtime-neutral interception point for reshaping a ``ToolResult`` after the tool has executed
/// and before the orchestrator forwards it to the model. Implementations are expected to be cheap
/// and deterministic; the harness does not run any LLM call on this seam.
public struct AgentToolResultMiddleware: Sendable {
    /// Stable identifier used for deterministic ordering ties and diagnostics.
    public let id: String
    /// Relative position within the runtime-delivery stage. Lower runs earlier; host middleware is
    /// applied between the harness subdirectory-hint tracker (order 50) and the external-content
    /// envelope (order 200).
    public let order: Int
    public let transform: @Sendable (ToolCall, ToolResult) async -> ToolResult

    public init(
        id: String,
        order: Int = 100,
        transform: @escaping @Sendable (ToolCall, ToolResult) async -> ToolResult
    ) {
        self.id = id
        self.order = order
        self.transform = transform
    }
}

struct ToolResultMiddlewareRegistration: Sendable {
    let id: String
    let stage: ToolResultMiddlewareStage
    let order: Int
    let transform: @Sendable (ToolCall, ToolResult) async -> ToolResult

    init(
        id: String,
        stage: ToolResultMiddlewareStage,
        order: Int = 0,
        transform: @escaping @Sendable (ToolCall, ToolResult) async -> ToolResult
    ) {
        self.id = id
        self.stage = stage
        self.order = order
        self.transform = transform
    }
}

struct ToolResultMiddlewarePipeline: Sendable {
    private let ordered: [ToolResultMiddlewareRegistration]

    init(registrations: [ToolResultMiddlewareRegistration]) {
        self.ordered = registrations.sorted {
            if $0.order == $1.order {
                return $0.id < $1.id
            }
            return $0.order < $1.order
        }
    }

    static var passthrough: ToolResultMiddlewarePipeline {
        ToolResultMiddlewarePipeline(registrations: [])
    }

    func apply(
        stage: ToolResultMiddlewareStage,
        toolCall: ToolCall,
        result: ToolResult
    ) async -> ToolResult {
        var current = result
        for middleware in ordered where middleware.stage == stage {
            current = await middleware.transform(toolCall, current)
        }
        return current
    }
}
