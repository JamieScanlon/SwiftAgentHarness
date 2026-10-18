import Foundation
import Logging
import SwiftAgentKit

protocol TriggerRuntimeDispatching: Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?,
        originSenderIsOwner: Bool?
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
    let logger: Logger

    init(
        activationPolicy: TriggerActivationPolicy,
        sessionRouter: TriggerSessionRouter,
        promptBuilder: TriggerPromptBuilder,
        runtime: any TriggerRuntimeDispatching,
        delegatedDispatch: TriggerDelegatedDispatchService? = nil,
        snapshotStore: TriggerSnapshotStore? = nil,
        channelRunStreaming: ChannelRunStreamingServiceHolder? = nil,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil,
        logger: Logger = Logger(label: "swift-agent-harness.triggers.dispatch")
    ) {
        self.activationPolicy = activationPolicy
        self.sessionRouter = sessionRouter
        self.promptBuilder = promptBuilder
        self.runtime = runtime
        self.delegatedDispatch = delegatedDispatch
        self.snapshotStore = snapshotStore
        self.channelRunStreaming = channelRunStreaming
        self.lifecycleCoordinator = lifecycleCoordinator
        self.logger = logger
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
            if route.routingMode == .threaded {
                logger.warning(
                    "trigger_threaded_route_nil_conversation id=\(resolved.id) source=\(resolved.source.rawValue)"
                )
            }
            activationPolicy.auditLog.record(
                TriggerAuditEntry.from(trigger: resolved, decision: .unauthorized)
            )
            return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
        }
        let built = promptBuilder.build(trigger: resolved)
        switch route.routingMode {
        case .delegated:
            guard let delegatedDispatch else {
                activationPolicy.auditLog.record(
                    TriggerAuditEntry.from(trigger: resolved, decision: .unauthorized)
                )
                return TriggerActivationResult(decision: .unauthorized, sessionID: nil)
            }
            // No sender verdict rides along here, and deliberately so: the child runs under the
            // `trigger-delegate` profile, whose deny list is derived from
            // `ToolControlPlaneClassification.confinedProfileDenyTokens` — every control-plane name
            // is already withheld from it regardless of who spoke.
            let childID = try await delegatedDispatch.dispatch(
                trigger: resolved,
                hostConversationID: conversationID,
                sessionKey: route.sessionKey,
                built: built
            )
            // Delegated runs get their own child conversation: the whole thing belongs to this
            // source, which is also how sub-agent fan-out rolls up.
            activationPolicy.budget?.indexRun(trigger: resolved, conversationID: childID)
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
                resolvedInputTrustClass: TriggerTrustCodec.executionPolicyClass(for: resolved.trust),
                enableTools: resolved.enableTools,
                enableAgents: resolved.enableAgents,
                originSurface: resolved.sourceMetadata["channel"] ?? resolved.source.rawValue,
                originSenderID: resolved.sourceMetadata["senderId"] ?? resolved.initiator.id,
                originSenderIsOwner: Self.senderIsOwner(for: resolved)
            )
            // Only isolated runs are billed by conversation. A threaded fire shares the user's
            // conversation with their own turns, so charging it would bill their typing to their
            // reminder; those fires are recorded as unattributed rather than mis-attributed.
            if route.routingMode == .isolated {
                activationPolicy.budget?.indexRun(trigger: resolved, conversationID: conversationID)
            }
            return TriggerActivationResult(decision: .admitted, sessionID: conversationID)
        }
    }

    /// The per-turn ownership verdict for a trigger, or `nil` when the source has no sender concept.
    ///
    /// **Only channel triggers carry one.** `ChannelTriggerBuilder` resolves
    /// `event.senderId == config.primaryUser` into `.user` vs `.external`, so for that source the
    /// initiator kind *is* the verdict, computed by the layer that knows the channel's `primaryUser`.
    ///
    /// Every other source is machinery, not a human: a cron fire is `.system`, a webhook is
    /// `.external`, an agent-registered task is `.agent`. None of those is "a human who is not the
    /// owner", so mapping them through `kind == .user` would stamp `false` on them and deny
    /// control-plane tools to the owner's own scheduled work.
    /// A channel with no configured `primaryUser` also asserts nothing. It cannot answer the
    /// question, so every sender lands on `.external`; reading that as "not the owner" would deny
    /// the operator their own control-plane tools on every message in a deployment that simply
    /// never set the key.
    static func senderIsOwner(for trigger: HarnessTrigger) -> Bool? {
        guard trigger.source == .channel else { return nil }
        guard trigger.sourceMetadata["channelOwnershipResolvable"] == "true" else { return nil }
        return trigger.initiator.kind == .user
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
