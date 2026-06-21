import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

/// Thin session coordinator contract (L1): selection mirror, domain bundle access, diagnostics-only orchestrator.
protocol HarnessRuntimeSessionCoordinating: Actor {
    var currentConversationID: UUID? { get async }
    var currentMessages: [Message] { get async }
    var runtimeDependencies: ConversationRuntimeDependencies { get }
    var conversationDomainServices: ConversationDomainServiceBundle { get }

    func currentConversation() async -> ModelConversation?
    func selectConversation(conversationID: UUID) async throws
    func sessionOrchestrator() async -> SwiftAgentKitOrchestrator?
    func sessionOrchestratorConversationID() async -> UUID?
}

/// Composition-root / gateway wiring refs (L1): injected service handles, not session behavior.
protocol HarnessRuntimeSessionWiring: Actor {
    var conversationDomainServices: ConversationDomainServiceBundle { get }
    var agentRuntimeSessionService: AgentRuntimeSessionService { get }
    var conversationReplayService: ConversationReplayService { get }
    var conversationToolModePolicyRuntimeService: ConversationToolModePolicyRuntimeService { get }
    var subAgentSpawnService: SubAgentSpawnService { get }
    var subAgentCompletionRuntimeService: SubAgentCompletionRuntimeService { get }
    var conversationStartupService: ConversationStartupService { get }
}

extension HarnessRuntimeSession: HarnessRuntimeSessionCoordinating {}
extension HarnessRuntimeSession: HarnessRuntimeSessionWiring {}
