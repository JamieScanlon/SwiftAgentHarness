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
    let channelRunStreaming: ChannelRunStreamingServiceHolder?
    let lifecycleCoordinator: ChannelSessionLifecycleCoordinator?

    init(
        activationPolicy: TriggerActivationPolicy,
        sessionRouter: TriggerSessionRouter,
        promptBuilder: TriggerPromptBuilder,
        runtime: any TriggerRuntimeDispatching,
        delegatedDispatch: TriggerDelegatedDispatchService? = nil,
        snapshotStore: TriggerSnapshotStore? = nil,
        channelRunStreaming: ChannelRunStreamingServiceHolder? = nil,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil
    ) {
        self.activationPolicy = activationPolicy
        self.sessionRouter = sessionRouter
        self.promptBuilder = promptBuilder
        self.runtime = runtime
        self.delegatedDispatch = delegatedDispatch
        self.snapshotStore = snapshotStore
        self.channelRunStreaming = channelRunStreaming
        self.lifecycleCoordinator = lifecycleCoordinator
    }

    func ingest(_ trigger: HarnessTrigger) async throws -> TriggerActivationResult {
        let resolved = trigger.withRootCorrelation()
        let decision = try await activationPolicy.evaluate(resolved)
        guard decision == .admitted else {
            return TriggerActivationResult(decision: decision, sessionID: nil)
        }
        try snapshotStore?.save(resolved)
        let route = try await sessionRouter.route(resolved)
        guard let conversationID = route.conversationID else {
            return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
        }
        let built = promptBuilder.build(trigger: resolved)
        switch route.routingMode {
        case .delegated:
            guard let delegatedDispatch else {
                return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
            }
            let childID = try await delegatedDispatch.dispatch(
                trigger: resolved,
                hostConversationID: conversationID,
                sessionKey: route.sessionKey,
                built: built
            )
            return TriggerActivationResult(decision: .admitted, sessionID: childID)
        case .isolated, .threaded:
            if resolved.source == .channel, let holder = channelRunStreaming, let service = holder.service() {
                await attachChannelRunStreaming(
                    service: service,
                    trigger: resolved,
                    conversationID: conversationID
                )
            }
            let outputReminder = resolved.source == .channel
                ? MessageOutputSystemPromptGuidance.channelOutputVerb
                : nil
            let mergedReminder = [built.systemReminder, outputReminder]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            try await runtime.dispatchTriggerMessage(
                conversationID: conversationID,
                text: built.userMessageBody,
                systemReminder: mergedReminder.isEmpty ? nil : mergedReminder,
                inputTrustRaw: TriggerTrustCodec.inputTrustRaw(for: resolved.trust),
                enableTools: resolved.enableTools,
                enableAgents: resolved.enableAgents,
                originSurface: resolved.sourceMetadata["channel"] ?? resolved.source.rawValue,
                originSenderID: resolved.sourceMetadata["senderId"] ?? resolved.initiator.id
            )
            return TriggerActivationResult(decision: .admitted, sessionID: conversationID)
        }
    }

    private func attachChannelRunStreaming(
        service: ChannelRunStreamingService,
        trigger: HarnessTrigger,
        conversationID: UUID
    ) async {
        guard let channelRaw = trigger.sourceMetadata["channel"],
              let channel = ChannelId(rawValue: channelRaw) else {
            return
        }
        await service.attach(
            conversationID: conversationID,
            target: ChannelRunStreamingTarget(
                channel: channel,
                chatId: trigger.sourceMetadata["chatId"] ?? "",
                threadId: trigger.sourceMetadata["threadId"],
                replyToMessageId: trigger.sourceMetadata["platformMessageId"]
            )
        )
        if let lifecycleCoordinator {
            let burstKeys = ChannelDebounceBurstKey.fromTriggerMetadata(trigger.sourceMetadata)
            if !burstKeys.isEmpty {
                await lifecycleCoordinator.bindBurstKeys(
                    conversationID: conversationID,
                    channel: channel,
                    burstKeys: burstKeys
                )
            }
        }
    }
}
