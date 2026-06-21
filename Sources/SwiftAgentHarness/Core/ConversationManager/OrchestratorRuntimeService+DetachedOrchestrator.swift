import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

struct BuiltOrchestrator: Sendable {
    let orchestrator: SwiftAgentKitOrchestrator
    let queuedLLM: QueuedLLM
    let conversationID: UUID?
}
