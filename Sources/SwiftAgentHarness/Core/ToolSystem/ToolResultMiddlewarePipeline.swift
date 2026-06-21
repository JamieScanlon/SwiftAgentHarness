import Foundation
import SwiftAgentKit

enum ToolResultMiddlewareStage: String, Sendable {
    case runtimeDelivery
    case persistence
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
