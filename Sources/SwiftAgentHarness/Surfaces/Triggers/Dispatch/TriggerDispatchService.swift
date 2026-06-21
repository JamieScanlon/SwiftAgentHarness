import Foundation
import SwiftAgentKit

protocol TriggerRuntimeDispatching: Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws
}

struct TriggerDispatchService: Sendable {
    let activationPolicy: TriggerActivationPolicy
    let sessionRouter: TriggerSessionRouter
    let promptBuilder: TriggerPromptBuilder
    let runtime: any TriggerRuntimeDispatching
    let delegatedDispatch: TriggerDelegatedDispatchService?
    let snapshotStore: TriggerSnapshotStore?

    init(
        activationPolicy: TriggerActivationPolicy,
        sessionRouter: TriggerSessionRouter,
        promptBuilder: TriggerPromptBuilder,
        runtime: any TriggerRuntimeDispatching,
        delegatedDispatch: TriggerDelegatedDispatchService? = nil,
        snapshotStore: TriggerSnapshotStore? = nil
    ) {
        self.activationPolicy = activationPolicy
        self.sessionRouter = sessionRouter
        self.promptBuilder = promptBuilder
        self.runtime = runtime
        self.delegatedDispatch = delegatedDispatch
        self.snapshotStore = snapshotStore
    }

    func ingest(_ trigger: HarnessTrigger) async throws -> TriggerActivationResult {
        let decision = try await activationPolicy.evaluate(trigger)
        guard decision == .admitted else {
            return TriggerActivationResult(decision: decision, sessionID: nil)
        }
        try snapshotStore?.save(trigger)
        let route = try await sessionRouter.route(trigger)
        guard let conversationID = route.conversationID else {
            return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
        }
        let built = promptBuilder.build(trigger: trigger)
        switch route.routingMode {
        case .delegated:
            guard let delegatedDispatch else {
                return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
            }
            let childID = try await delegatedDispatch.dispatch(
                trigger: trigger,
                hostConversationID: conversationID,
                sessionKey: route.sessionKey,
                built: built
            )
            return TriggerActivationResult(decision: .admitted, sessionID: childID)
        case .isolated, .threaded:
            try await runtime.dispatchTriggerMessage(
                conversationID: conversationID,
                text: built.userMessageBody,
                systemReminder: built.systemReminder,
                inputTrustRaw: TriggerTrustCodec.inputTrustRaw(for: trigger.trust),
                enableTools: trigger.enableTools,
                enableAgents: trigger.enableAgents,
                originSurface: trigger.sourceMetadata["channel"] ?? trigger.source.rawValue,
                originSenderID: trigger.sourceMetadata["senderId"] ?? trigger.initiator.id
            )
            return TriggerActivationResult(decision: .admitted, sessionID: conversationID)
        }
    }
}
