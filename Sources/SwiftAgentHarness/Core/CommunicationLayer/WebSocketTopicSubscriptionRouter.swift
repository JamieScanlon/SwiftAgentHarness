import Foundation
import SwiftAgentKit

/// Harness `kind: subscribe` / `unsubscribe` / `ack` / `dedupe_check_and_set` routing for multiplexed WebSocket topics (`model/...`, `conversation/...`, pool health, model registry, session capability registries).
/// Lives in ``Communication`` so topic naming and hub delegation stay out of the Vapor gateway.
enum WebSocketTopicSubscriptionRouter {
    /// Applies control message to hubs. Returns an error message for the gateway to send as `type: error`, or `nil` on success.
    static func applyCommClientControlMessage(
        modelHub: ModelStateTopicHub?,
        conversationHub: ConversationEventsTopicHub?,
        conversationStateHub: ConversationStateTopicHub?,
        traceHub: TraceTopicHub?,
        subAgentLifecycleHub: SubAgentLifecycleTopicHub?,
        capabilityRegistryHub: CapabilityRegistryTopicHub?,
        conversationsRegistryHub: ConversationsRegistryTopicHub?,
        coordinator: ModelInvocationCoordinator?,
        conversationSession: APILayerConversationManaging?,
        chatRuntime: APILayerChatRuntimeManaging?,
        budgetReporting: any BudgetReporting = NilBudgetReporting(),
        modelManager: APILayerModelManaging?,
        resumeTokenHMACSecret: String? = nil,
        inboundDedupeDefaultTtlSeconds: Int = 600,
        inboundDedupeMaxTtlSeconds: Int = 3600,
        inboundDedupePerform: (@Sendable (String, Int) async throws -> Bool)? = nil,
        inboundDedupeRespond: (@Sendable (Bool) async throws -> Void)? = nil,
        serverTraceSubscribePolicy: ServerTraceSubscribePolicy = .open,
        conversationEventsReplayRetention: TranscriptTailRetentionPolicy = .fromEnvironmentOrDefault(),
        tenancyPolicy: TenancyPolicySettings = .disabled,
        message: CommClientControlMessage,
        registration: WebSocketTopicWireRegistration
    ) async -> String? {
        switch message.kind {
        case .dedupeCheckAndSet:
            guard let perform = inboundDedupePerform, let respond = inboundDedupeRespond else {
                return "Inbound dedupe is not configured on this connection"
            }
            guard let rawKey = message.dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty else {
                return "dedupe_check_and_set requires dedupeKey"
            }
            let cap = max(1, inboundDedupeMaxTtlSeconds)
            let ttlRequested = message.dedupeTtlSeconds ?? max(1, inboundDedupeDefaultTtlSeconds)
            let ttl = min(max(ttlRequested, 1), cap)
            do {
                let first = try await perform(rawKey, ttl)
                try await respond(first)
            } catch {
                return "Dedupe failed: \(error)"
            }
            return nil

        case .ack:
            guard let topic = message.topic, !topic.isEmpty else {
                return "Ack requires a topic"
            }
            guard let upTo = message.upTo else {
                return "Ack requires upTo"
            }
            if let limiter = registration.outboundFlowLimiter {
                await limiter.applyAck(topic: topic, upTo: upTo)
            }
            return nil

        case .subscribe:
            guard let topic = message.topic else {
                return "Subscribe requires a topic"
            }
            let trimmedResume = (message.resumeToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasResume = !trimmedResume.isEmpty
            let hasDual = message.sinceMessageSeq != nil || message.sinceCheckpointSeq != nil
            if hasResume || hasDual {
                guard ConversationTopicFormat.parseConversationEventsTopic(topic) != nil else {
                    return "sinceMessageSeq, sinceCheckpointSeq, and resumeToken are only valid for conversation/{id}/events"
                }
            }
            if let conversationID = ConversationTopicFormat.parseConversationEventsTopic(topic) {
                guard let conversationHub else {
                    return "Conversation events wire is not configured on this server"
                }
                guard let token = registration.conversationEventsTopicHubToken else {
                    return "Conversation events subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: conversationID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }

                let snapshot: @Sendable (UUID) async -> String = { cid in
                    let rows = await snapshotMessages(conversationSession: conversationSession, conversationID: cid)
                    let seq = await conversationSession.apiLatestTranscriptSequence(conversationID: cid)
                    return ConversationTopicWireEncoding.messagesRefreshJSONUTF8(from: rows, latestTranscriptSequence: seq)
                }
                do {
                    let replayRequest: ConversationEventsReplayRequest
                    if hasResume {
                        if message.since != nil || hasDual {
                            return "resumeToken cannot be combined with since or sinceMessageSeq/sinceCheckpointSeq"
                        }
                        guard let secretRaw = resumeTokenHMACSecret, !secretRaw.isEmpty else {
                            return "Resume tokens are not configured on this server"
                        }
                        let payload = try ConversationEventsResumeToken.parse(
                            trimmedResume,
                            secret: Data(secretRaw.utf8),
                            conversationID: conversationID
                        )
                        replayRequest = .dual(sinceMessage: payload.msg, sinceCheckpoint: payload.chk)
                    } else if hasDual {
                        if message.since != nil {
                            return "since cannot be combined with sinceMessageSeq or sinceCheckpointSeq"
                        }
                        replayRequest = .dual(
                            sinceMessage: message.sinceMessageSeq,
                            sinceCheckpoint: message.sinceCheckpointSeq
                        )
                    } else {
                        replayRequest = .totalOrderSince(message.since)
                    }

                    let transcriptReplay: ConversationTranscriptSubscribeReplay
                    do {
                        transcriptReplay = try await conversationEventsTranscriptReplay(
                            conversationID: conversationID,
                            replay: replayRequest,
                            session: conversationSession,
                            retention: conversationEventsReplayRetention
                        )
                    } catch {
                        return "Subscribe failed: \(error)"
                    }
                    let transcriptHead = await conversationSession.apiLatestTranscriptSequence(conversationID: conversationID) ?? 0
                    let wireHead = await conversationHub.currentSeq(forConversationID: conversationID)
                    let snapHead = max(transcriptHead, wireHead)
                    try await conversationHub.subscribe(
                        token: token,
                        conversationID: conversationID,
                        replay: replayRequest,
                        transcriptReplay: transcriptReplay,
                        snapshotMessagesJSONUTF8: snapshot,
                        snapshotTranscriptSequence: snapHead
                    )
                } catch let e as ConversationEventsResumeTokenError {
                    return resumeTokenClientMessage(e)
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if let conversationID = ConversationTopicFormat.parseConversationStateTopic(topic) {
                guard let conversationStateHub else {
                    return "Conversation state wire is not configured on this server"
                }
                guard let token = registration.conversationStateTopicHubToken else {
                    return "Conversation state subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: conversationID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                let poolStateProvider: ConversationStateSnapshotBuilder.PoolStateProvider?
                let activeCallProvider: ConversationStateSnapshotBuilder.ActiveCallProvider?
                if let coord = coordinator {
                    poolStateProvider = { modelID in
                        guard await coord.latestPhase(for: modelID) != nil else { return nil }
                        return await coord.snapshot(for: modelID)
                    }
                    activeCallProvider = { conversationID in
                        await coord.activeCall(forConversationID: conversationID)
                    }
                } else {
                    poolStateProvider = nil
                    activeCallProvider = nil
                }
                let reporter = budgetReporting
                let projectedCostProvider: ConversationStateSnapshotBuilder.ProjectedCostProvider = { conversationID in
                    await reporter.projectedCostUSD(conversationID: conversationID)
                }
                let projectionBudgetProvider: ConversationStateSnapshotBuilder.ProjectionBudgetProvider = { conversationID in
                    await conversationSession.apiProjectionContextBudget(conversationID: conversationID)
                }
                do {
                    try await conversationStateHub.subscribe(
                        token: token,
                        conversationID: conversationID,
                        since: message.since
                    ) { cid in
                        await ConversationStateSnapshotBuilder.build(
                            conversationID: cid,
                            conversation: conversationSession,
                            runtime: chatRuntime,
                            poolStateProvider: poolStateProvider,
                            activeCallProvider: activeCallProvider,
                            projectedCostProvider: projectedCostProvider,
                            projectionBudgetProvider: projectionBudgetProvider
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if let parsed = SubAgentTopicFormat.parseEventsTopic(topic) {
                guard let subAgentLifecycleHub else {
                    return "Sub-agent lifecycle wire is not configured on this server"
                }
                guard let token = registration.subAgentLifecycleTopicHubToken else {
                    return "Sub-agent lifecycle subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: parsed.conversationID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await subAgentLifecycleHub.subscribe(
                        token: token,
                        topic: topic,
                        parentConversationID: parsed.conversationID,
                        since: message.since
                    ) { _ in
                        await conversationSession.apiSubAgentLifecycleSnapshot(
                            conversationID: parsed.conversationID,
                            pathSegments: parsed.pathSegments
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if let parsed = SubAgentTopicFormat.parseStateTopic(topic) {
                guard let subAgentLifecycleHub else {
                    return "Sub-agent lifecycle wire is not configured on this server"
                }
                guard let token = registration.subAgentLifecycleTopicHubToken else {
                    return "Sub-agent lifecycle subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: parsed.conversationID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await subAgentLifecycleHub.subscribe(
                        token: token,
                        topic: topic,
                        parentConversationID: parsed.conversationID,
                        since: message.since
                    ) { _ in
                        await conversationSession.apiSubAgentLifecycleSnapshot(
                            conversationID: parsed.conversationID,
                            pathSegments: parsed.pathSegments
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if let conversationID = TraceTopicFormat.parseConversationTopic(topic) {
                guard let traceHub else {
                    return "Trace wire is not configured on this server"
                }
                guard let token = registration.traceTopicHubToken else {
                    return "Trace subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: conversationID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await traceHub.subscribe(
                        token: token,
                        topic: topic,
                        since: message.since
                    ) {
                        await conversationSession.apiConversationTraceSnapshot(conversationID: conversationID)
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if TraceTopicFormat.isServerTopic(topic) {
                guard let traceHub else {
                    return "Trace wire is not configured on this server"
                }
                guard let token = registration.traceTopicHubToken else {
                    return "Trace subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForOperatorScopedSubscribe(
                    authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
                    policy: serverTraceSubscribePolicy
                ) {
                    return denied
                }
                do {
                    try await traceHub.subscribe(
                        token: token,
                        topic: topic,
                        since: message.since
                    ) {
                        await conversationSession.apiServerTraceSnapshot()
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            if topic == ResourceTopicName.toolsRegistry {
                guard let capabilityRegistryHub else {
                    return "Capability registry wire is not configured on this server"
                }
                guard let token = registration.capabilityRegistryTopicHubToken else {
                    return "Capability registry subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                guard let registryCID = Self.registryConversationID(from: message) else {
                    return "Subscribe to tools/registry requires conversationId (UUID string)"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: registryCID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await capabilityRegistryHub.subscribeToolsRegistry(token: token, since: message.since) {
                        await CapabilityRegistrySnapshotBuilder.buildTools(
                            conversation: conversationSession,
                            conversationID: registryCID
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            if topic == ResourceTopicName.skillsRegistry {
                guard let capabilityRegistryHub else {
                    return "Capability registry wire is not configured on this server"
                }
                guard let token = registration.capabilityRegistryTopicHubToken else {
                    return "Capability registry subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                guard let registryCID = Self.registryConversationID(from: message) else {
                    return "Subscribe to skills/registry requires conversationId (UUID string)"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: registryCID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await capabilityRegistryHub.subscribeSkillsRegistry(token: token, since: message.since) {
                        await CapabilityRegistrySnapshotBuilder.buildSkills(
                            conversation: conversationSession,
                            conversationID: registryCID
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            if topic == ResourceTopicName.subAgentsRegistry {
                guard let capabilityRegistryHub else {
                    return "Capability registry wire is not configured on this server"
                }
                guard let token = registration.capabilityRegistryTopicHubToken else {
                    return "Capability registry subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                guard let registryCID = Self.registryConversationID(from: message) else {
                    return "Subscribe to sub-agents/registry requires conversationId (UUID string)"
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForConversationObservation(
                    conversationID: registryCID,
                    session: conversationSession,
                    tenancyPolicy: tenancyPolicy
                ) {
                    return denied
                }
                do {
                    try await capabilityRegistryHub.subscribeSubAgentsRegistry(token: token, since: message.since) {
                        await CapabilityRegistrySnapshotBuilder.buildSubAgents(
                            conversation: conversationSession,
                            conversationID: registryCID
                        )
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            if topic == ResourceTopicName.conversationsRegistry {
                guard let conversationsRegistryHub else {
                    return "Conversations registry wire is not configured on this server"
                }
                guard let token = registration.conversationsRegistryTopicHubToken else {
                    return "Conversations registry subscription is not ready yet; retry subscribe"
                }
                guard let conversationSession else {
                    return "Chat manager is not configured"
                }
                if let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForConversationsRegistrySubscribe(
                    tenancyPolicy: tenancyPolicy,
                    authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID
                ) {
                    return denied
                }
                do {
                    try await conversationsRegistryHub.subscribeConversationsRegistry(token: token, since: message.since) {
                        await ConversationsRegistrySnapshotBuilder.snapshot(conversation: conversationSession)
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }

            guard let hub = modelHub else {
                return "Model pool wire is not configured on this server"
            }
            guard let token = registration.modelTopicHubToken else {
                return "Model pool subscription is not ready yet; retry subscribe"
            }
            if topic == ResourceTopicName.poolHealth {
                if let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForOperatorScopedSubscribe(
                    authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
                    policy: serverTraceSubscribePolicy
                ) {
                    return denied
                }
                do {
                    try await hub.subscribePoolHealth(token: token, since: message.since)
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            if topic == ResourceTopicName.modelsRegistry {
                do {
                    try await hub.subscribeModelsRegistry(token: token, since: message.since)
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            if let modelID = ModelCallsTopicFormat.parseModelCallsTopic(topic) {
                guard let coord = coordinator else {
                    return "Model state wire is not configured on this server"
                }
                guard let modelManager else {
                    return WebSocketTopicSubscribeAuthorization.deniedMessage
                }
                if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForModelStateSubscribe(
                    modelID: modelID,
                    modelManager: modelManager
                ) {
                    return denied
                }
                do {
                    try await hub.subscribeModelCalls(
                        token: token,
                        modelID: modelID,
                        since: message.since
                    ) { mid in
                        await coord.callsSnapshot(for: mid)
                    }
                } catch {
                    return "Subscribe failed: \(error)"
                }
                return nil
            }
            guard let modelID = ModelStateTopicFormat.parseModelStateTopic(topic) else {
                return "Invalid or unsupported topic"
            }
            guard let coord = coordinator else {
                return "Model state wire is not configured on this server"
            }
            guard let modelManager else {
                return WebSocketTopicSubscribeAuthorization.deniedMessage
            }
            if let denied = await WebSocketTopicSubscribeAuthorization.deniedReasonForModelStateSubscribe(
                modelID: modelID,
                modelManager: modelManager
            ) {
                return denied
            }
            do {
                try await hub.subscribe(
                    token: token,
                    modelID: modelID,
                    since: message.since
                ) { mid in
                    await coord.snapshot(for: mid)
                }
            } catch {
                return "Subscribe failed: \(error)"
            }
            return nil

        case .unsubscribe:
            guard let topic = message.topic else { return nil }
            if ConversationTopicFormat.parseConversationEventsTopic(topic) != nil {
                if let conversationHub, let convToken = registration.conversationEventsTopicHubToken {
                    await conversationHub.unsubscribe(token: convToken, topic: topic)
                }
                return nil
            }
            if ConversationTopicFormat.parseConversationStateTopic(topic) != nil {
                if let conversationStateHub, let stateToken = registration.conversationStateTopicHubToken {
                    await conversationStateHub.unsubscribe(token: stateToken, topic: topic)
                }
                return nil
            }
            if SubAgentTopicFormat.parseEventsTopic(topic) != nil || SubAgentTopicFormat.parseStateTopic(topic) != nil {
                if let subAgentLifecycleHub, let token = registration.subAgentLifecycleTopicHubToken {
                    await subAgentLifecycleHub.unsubscribe(token: token, topic: topic)
                }
                return nil
            }
            if TraceTopicFormat.parseConversationTopic(topic) != nil || TraceTopicFormat.isServerTopic(topic) {
                if let traceHub, let token = registration.traceTopicHubToken {
                    await traceHub.unsubscribe(token: token, topic: topic)
                }
                return nil
            }
            if topic == ResourceTopicName.toolsRegistry
                || topic == ResourceTopicName.skillsRegistry
                || topic == ResourceTopicName.subAgentsRegistry
            {
                if let capabilityRegistryHub, let capToken = registration.capabilityRegistryTopicHubToken {
                    await capabilityRegistryHub.unsubscribe(token: capToken, topic: topic)
                }
                return nil
            }
            if topic == ResourceTopicName.conversationsRegistry {
                if let conversationsRegistryHub, let regToken = registration.conversationsRegistryTopicHubToken {
                    await conversationsRegistryHub.unsubscribe(token: regToken, topic: topic)
                }
                return nil
            }
            if let hub = modelHub, let modelToken = registration.modelTopicHubToken {
                await hub.unsubscribe(token: modelToken, topic: topic)
            }
            return nil
        }
    }

    private static func registryConversationID(from message: CommClientControlMessage) -> UUID? {
        guard let raw = message.conversationId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private static func snapshotMessages(
        conversationSession: APILayerConversationManaging,
        conversationID: UUID
    ) async -> [Message] {
        if let rows = try? await conversationSession.apiListMessagesThrowing(conversationID: conversationID) {
            return rows
        }
        if let conv = await conversationSession.apiGetConversation(id: conversationID) {
            return conv.messages
        }
        return []
    }

    private static func conversationEventsTranscriptReplay(
        conversationID: UUID,
        replay: ConversationEventsReplayRequest,
        session: APILayerConversationManaging,
        retention: TranscriptTailRetentionPolicy
    ) async throws -> ConversationTranscriptSubscribeReplay {
        let latest = await session.apiLatestTranscriptSequence(conversationID: conversationID) ?? 0
        if let floor = ConversationEventsTranscriptReplayHydrator.replayInclusiveFloor(replay) {
            try retention.requireReplayWindow(
                conversationID: conversationID,
                clientInclusiveFloor: floor,
                latestSequence: latest
            )
        }
        let entries = try await session.apiReadTranscriptEntries(conversationID: conversationID, request: .full)
        let heads = ConversationEventsTranscriptReplayHydrator.streamHeads(entries: entries)
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        let (lines, lagging) = ConversationEventsTranscriptReplayHydrator.persistedReplayLines(
            topic: topic,
            conversationID: conversationID,
            replay: replay,
            entries: entries,
            latestTranscriptSequence: latest
        )
        return ConversationTranscriptSubscribeReplay(
            latestTotal: latest,
            latestMessage: heads.latestMessage,
            latestCheckpoint: heads.latestCheckpoint,
            persistedReplayLines: lines,
            forceLagging: lagging
        )
    }

    private static func resumeTokenClientMessage(_ error: ConversationEventsResumeTokenError) -> String {
        switch error {
        case .malformed:
            return "Invalid resume token: malformed"
        case .badVersion:
            return "Invalid resume token: unsupported version"
        case .badSignature:
            return "Invalid resume token: bad signature"
        case .expired:
            return "Invalid resume token: expired"
        case .conversationMismatch:
            return "Invalid resume token: topic mismatch"
        }
    }
}
