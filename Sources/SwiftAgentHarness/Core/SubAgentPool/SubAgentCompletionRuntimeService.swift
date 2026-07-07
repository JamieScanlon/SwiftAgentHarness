import Foundation
import SwiftAgentKit

/// Sub-agent completion announcement ingestion and startup reconciliation (Slice 4 migration).
public actor SubAgentCompletionRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let orchestrationCore: AgentRuntimeOrchestrationCore
    private let messaging: ConversationMessagingPort
    private let topics: ConversationTopicPublicationPort
    nonisolated(unsafe) private var spawn: (any SubAgentSpawnDelegating)!
    private let subAgentCompletionService = SubAgentCompletionService()
    private let completionAnnounceMaxRetryAttempts = 3

    init(
        deps: ConversationRuntimeDependencies,
        orchestrationCore: AgentRuntimeOrchestrationCore,
        messaging: ConversationMessagingPort,
        topics: ConversationTopicPublicationPort
    ) {
        self.deps = deps
        self.orchestrationCore = orchestrationCore
        self.messaging = messaging
        self.topics = topics
    }

    nonisolated func installSpawn(_ spawn: any SubAgentSpawnDelegating) {
        precondition(self.spawn == nil, "SubAgentSpawnService already installed")
        self.spawn = spawn
    }

    private var installedSpawn: any SubAgentSpawnDelegating {
        guard let spawn else {
            preconditionFailure("SubAgentSpawnService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return spawn
    }


    func registerHandleOwnership(
        conversationID: UUID,
        sessionHandleID: String,
        completionHandleID: String?
    ) async {
        await subAgentCompletionService.registerHandleOwnership(
            conversationID: conversationID,
            sessionHandleID: sessionHandleID,
            completionHandleID: completionHandleID
        )
    }

    func resolveConversationIDForHandle(handleID: String, fallbackSessionHandleID: String?) async -> UUID? {
        await subAgentCompletionService.resolveConversationIDForHandle(
            handleID: handleID,
            fallbackSessionHandleID: fallbackSessionHandleID
        )
    }

    func ingestCompletionAnnouncementForAPI(
        _ announce: CompletionAnnouncePayload,
        toolMessageContent: String?
    ) async {
        let message = toolMessageContent.map { content in
            Message(
                id: UUID(),
                role: .tool,
                content: content,
                timestamp: announce.completedAt,
                toolCallId: announce.toolCallID
            )
        }
        await ingestCompletionAnnouncement(announce, toolMessage: message)
    }

    func retryPendingCompletionAnnouncements() async {
        let pending = await subAgentCompletionService.pendingAnnouncements()
        for announce in pending {
            guard await subAgentCompletionService.tryBeginDelivery(
                delegateHandleID: announce.delegateHandleID,
                toolCallID: announce.toolCallID
            ) else {
                continue
            }
            let retries = await subAgentCompletionService.recordRetry(for: announce.announceID)
            if retries > completionAnnounceMaxRetryAttempts {
                try? await deps.persistenceDomain.routingPersistCompletionAnnounceEventAsync(
                    conversationID: announce.conversationID,
                    payload: CompletionAnnounceEventPayload(
                        announce: announce,
                        runtimePublished: false,
                        subagentPublished: await publishSubagentCompletionLifecycle(announce: announce),
                        retryCount: retries,
                        deliveryState: "fallback",
                        createdAt: Date()
                    )
                )
                await subAgentCompletionService.clearPending(announceID: announce.announceID)
                continue
            }
            let conversation = await deps.persistenceDomain.modelConversation(id: announce.conversationID)
            let toolName = conversation?.messages
                .reversed()
                .compactMap { message in
                    message.toolCalls.first(where: { $0.id == announce.toolCallID })?.name
                }
                .first
            let runtimePublished = await emitPendingCompletionRuntimeLifecycle(
                announce: announce,
                runID: conversation?.currentRunID,
                toolName: toolName
            )
            let subagentPublished = await publishSubagentCompletionLifecycle(announce: announce)
            try? await deps.persistenceDomain.routingPersistCompletionAnnounceEventAsync(
                conversationID: announce.conversationID,
                payload: CompletionAnnounceEventPayload(
                    announce: announce,
                    runtimePublished: runtimePublished,
                    subagentPublished: subagentPublished,
                    retryCount: retries,
                    deliveryState: runtimePublished ? "delivered" : "pending",
                    createdAt: Date()
                )
            )
            if runtimePublished {
                await subAgentCompletionService.markDelivered(announce)
            } else {
                await subAgentCompletionService.markPending(announce)
            }
        }
    }

    func reconcileUnresolvedCompletionAnnouncementsOnStartup() async {
        for info in await deps.persistenceDomain.listConversationInfo() {
            let unresolved = await unresolvedCompletionAnnouncements(conversationID: info.id)
            for item in unresolved {
                await subAgentCompletionService.markPending(item)
            }
        }
    }

    func resolvePendingCompletionConversationID(toolCallID: String, handleID: String? = nil) async -> UUID? {
        if let handleID,
           let mappedConversationID = await subAgentCompletionService.resolveConversationIDForHandle(
                handleID: handleID,
                fallbackSessionHandleID: nil
           ) {
            return mappedConversationID
        }
        for info in await deps.persistenceDomain.listConversationInfo() {
            guard let conversation = await deps.persistenceDomain.modelConversation(id: info.id) else { continue }
            if conversation.messages.contains(where: { message in
                message.toolCalls.contains(where: { $0.id == toolCallID })
            }) {
                return info.id
            }
        }
        return nil
    }

    func ingestPendingCompletionEvent(_ event: SubAgentPendingCompletionEvent) async {
        let lifecycleID = event.launchHandleID ?? event.completion.handleID
        let announce = CompletionAnnouncePayload(
            delegateHandleID: event.completion.handleID,
            toolCallID: event.completion.toolCallID,
            conversationID: event.conversationID,
            parentConversationID: await deps.persistenceDomain.modelConversation(id: event.conversationID)?.parentConversationID,
            lifecycleID: lifecycleID,
            status: event.completion.result.success ? .done : .failed,
            completedAt: event.completion.completedAt,
            source: event.launchHandleID == nil ? "runtime.pendingCompletion" : "subAgentPool.pendingCompletion",
            usage: nil,
            error: event.completion.result.success ? nil : (event.completion.result.error ?? "tool_execution_failed")
        )
        await ingestCompletionAnnouncement(announce, toolMessage: event.toolMessage)
    }

    // MARK: - Private

    private func ingestCompletionAnnouncement(
        _ announce: CompletionAnnouncePayload,
        toolMessage: Message? = nil
    ) async {
        let normalizedAnnounce = CompletionAnnouncePayload(
            schemaVersion: announce.schemaVersion,
            announceID: announce.announceID,
            delegateHandleID: announce.delegateHandleID,
            toolCallID: announce.toolCallID,
            conversationID: announce.conversationID,
            parentConversationID: announce.parentConversationID,
            lifecycleID: announce.lifecycleID,
            status: announce.status,
            completedAt: announce.completedAt,
            source: announce.source,
            usage: sanitizedCompletionUsage(announce.usage),
            error: announce.error
        )
        guard await subAgentCompletionService.tryBeginDelivery(
            delegateHandleID: normalizedAnnounce.delegateHandleID,
            toolCallID: normalizedAnnounce.toolCallID
        ) else {
            return
        }
        if await hasPersistedCompletionAnnounceMarker(
            conversationID: normalizedAnnounce.conversationID,
            delegateHandleID: normalizedAnnounce.delegateHandleID,
            toolCallID: normalizedAnnounce.toolCallID
        ) {
            await subAgentCompletionService.markDelivered(normalizedAnnounce)
            return
        }
        if let toolMessage {
            let hasExisting = await hasExistingToolCompletionMessage(
                conversationID: normalizedAnnounce.conversationID,
                toolCallID: normalizedAnnounce.toolCallID
            )
            if !hasExisting {
            await messaging.appendMessagesToConversation(
                [toolMessage],
                conversationID: normalizedAnnounce.conversationID
            )
            }
        }
        let conversation = await deps.persistenceDomain.modelConversation(id: normalizedAnnounce.conversationID)
        let toolName = conversation?.messages
            .reversed()
            .compactMap { message in
                message.toolCalls.first(where: { $0.id == normalizedAnnounce.toolCallID })?.name
            }
            .first
        let subagentPublished = await publishSubagentCompletionLifecycle(announce: normalizedAnnounce)
        let runtimePublished = await emitPendingCompletionRuntimeLifecycle(
            announce: normalizedAnnounce,
            runID: conversation?.currentRunID,
            toolName: toolName
        )
        _ = await subAgentCompletionService.recordRetry(for: normalizedAnnounce.announceID)
        try? await deps.persistenceDomain.routingPersistCompletionAnnounceEventAsync(
            conversationID: normalizedAnnounce.conversationID,
            payload: CompletionAnnounceEventPayload(
                announce: normalizedAnnounce,
                runtimePublished: runtimePublished,
                subagentPublished: subagentPublished,
                retryCount: 1,
                deliveryState: runtimePublished ? "delivered" : "pending",
                createdAt: Date()
            )
        )
        if runtimePublished {
            await subAgentCompletionService.markDelivered(normalizedAnnounce)
        } else {
            await subAgentCompletionService.markPending(normalizedAnnounce)
        }
        await settleDelegateCompletionCost(normalizedAnnounce)
    }

    private func publishSubagentCompletionLifecycle(announce: CompletionAnnouncePayload) async -> Bool {
        guard let parentConversationID = announce.parentConversationID else { return false }
        let event = SubAgentDelegateEvent(
            lifecycleID: announce.lifecycleID,
            parentConversationID: parentConversationID,
            childConversationID: announce.conversationID,
            delegateToolName: nil,
            asyncHandleID: announce.delegateHandleID,
            phase: announce.status == .done ? .done : .failed,
            eventTrustLevel: nil,
            defaultTrustLevel: nil,
            permissionPolicy: nil,
            approvalRoute: await approvalRouteForConversation(conversationID: parentConversationID),
            completionAnnounceID: announce.announceID,
            toolCallID: announce.toolCallID,
            completionSource: announce.source,
            completionUsage: announce.usage,
            error: announce.error,
            updatedAt: announce.completedAt
        )
        await installedSpawn.applySubAgentDelegateEvent(event)
        return await installedSpawn.subAgentLifecyclePublisherConfigured()
    }

    private func settleDelegateCompletionCost(_ announce: CompletionAnnouncePayload) async {
        guard let delegateCostTracker = deps.delegateCostTracker else { return }
        let settledCostUSD = sanitizedCompletionUsage(announce.usage)?.costUSD
        await delegateCostTracker.recordDelegateCompletion(
            conversationID: announce.conversationID,
            success: announce.status == .done,
            settledCostUSD: settledCostUSD,
            completionAnnounceID: announce.announceID
        )
        await messaging.persistDelegateSpendSnapshot(conversationID: announce.conversationID)
    }

    private func emitPendingCompletionRuntimeLifecycle(
        announce: CompletionAnnouncePayload,
        runID: UUID?,
        toolName: String?
    ) async -> Bool {
        let topicPublisherConfigured = await installedSpawn.conversationTopicPublisherConfigured()
        guard let conversation = await deps.persistenceDomain.modelConversation(id: announce.conversationID) else { return false }
        let normalizedToolName = normalizedRuntimeString(toolName) ?? "tool_completion_unknown"
        let payload = RuntimeLifecycleEventPayload(
            name: .toolCompletionAnnounced,
            conversationID: announce.conversationID,
            runID: runID ?? conversation.currentRunID,
            toolName: normalizedToolName,
            parentConversationID: announce.parentConversationID ?? conversation.parentConversationID,
            childConversationID: announce.parentConversationID == nil ? nil : announce.conversationID,
            delegateHandleID: announce.delegateHandleID,
            toolCallID: announce.toolCallID,
            completionAnnounceID: announce.announceID,
            usage: announce.usage,
            source: announce.source,
            updatedAt: announce.completedAt
        )
        await topics.publishRuntimeLifecycleWithFanout(payload)
        return topicPublisherConfigured
    }

    private func hasExistingToolCompletionMessage(conversationID: UUID, toolCallID: String) async -> Bool {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else { return false }
        return conversation.messages.contains {
            $0.role == .tool && $0.toolCallId == toolCallID
        }
    }

    private func unresolvedCompletionAnnouncements(conversationID: UUID) async -> [CompletionAnnouncePayload] {
        let (events, _) = await deps.persistenceDomain.loadConversationEventsWithFrontier(conversationID: conversationID)
        var latestByAnnounceID: [UUID: CompletionAnnounceEventPayload] = [:]
        for event in events where event.kind == ConversationEventKind.completionAnnounceEvent.rawValue {
            guard let decoded = ConversationEventCodec.decode(CompletionAnnounceEventPayload.self, from: event.payloadJSON) else { continue }
            latestByAnnounceID[decoded.announce.announceID] = decoded
        }
        return latestByAnnounceID.values.compactMap { payload in
            guard payload.deliveryState == "pending", payload.retryCount < completionAnnounceMaxRetryAttempts else { return nil }
            return payload.announce
        }
    }

    private func hasPersistedCompletionAnnounceMarker(
        conversationID: UUID,
        delegateHandleID: String,
        toolCallID: String
    ) async -> Bool {
        let (events, _) = await deps.persistenceDomain.loadConversationEventsWithFrontier(conversationID: conversationID)
        return events.contains { event in
            guard event.kind == ConversationEventKind.completionAnnounceEvent.rawValue,
                  let decoded = ConversationEventCodec.decode(CompletionAnnounceEventPayload.self, from: event.payloadJSON) else {
                return false
            }
            return decoded.deliveryState == "delivered"
                && decoded.announce.delegateHandleID == delegateHandleID
                && decoded.announce.toolCallID == toolCallID
        }
    }

    private func sanitizedCompletionUsage(_ usage: DelegateCompletionUsagePayload?) -> DelegateCompletionUsagePayload? {
        guard let usage else { return nil }
        let promptTokens = max(0, usage.promptTokens ?? 0)
        let completionTokens = max(0, usage.completionTokens ?? 0)
        let providedTotal = max(0, usage.totalTokens ?? 0)
        let normalizedTotal = providedTotal > 0 ? providedTotal : max(0, promptTokens + completionTokens)
        let normalizedCost = max(0, usage.costUSD ?? 0)
        let hasSignal = promptTokens > 0 || completionTokens > 0 || normalizedTotal > 0 || normalizedCost > 0
        guard hasSignal else { return nil }
        return DelegateCompletionUsagePayload(
            promptTokens: promptTokens > 0 ? promptTokens : nil,
            completionTokens: completionTokens > 0 ? completionTokens : nil,
            totalTokens: normalizedTotal > 0 ? normalizedTotal : nil,
            costUSD: normalizedCost > 0 ? normalizedCost : nil
        )
    }

    private func normalizedRuntimeString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func approvalRouteForConversation(conversationID: UUID) async -> ToolApprovalRoute {
        if let conversation = await deps.persistenceDomain.modelConversation(id: conversationID),
           conversation.parentConversationID != nil {
            return .parent
        }
        return .user
    }
}
