import Foundation

/// Builds [`ConversationStatePayload`] for subscribe snapshots and state-topic refreshes.
enum ConversationStateSnapshotBuilder {
    /// Resolves the pool-derived ``ModelStatePayload`` for the conversation's selected `modelID`. Returns
    /// `nil` when the coordinator has never observed a transition for that model so we don't forge a
    /// synthetic ``.done`` snapshot.
    typealias PoolStateProvider = @Sendable (UUID) async -> ModelStatePayload?

    /// Resolves the currently dispatched `(modelID, callID)` for a conversation, if any (coordinator
    /// reverse lookup over `activeConversationID`). Returns `nil` when no active call.
    typealias ActiveCallProvider = @Sendable (UUID) async -> (modelID: UUID, callID: UUID)?

    /// Resolves projected USD spend for a conversation. Default ``NilBudgetReporting`` returns `nil`
    /// so the field stays absent until real accounting lands.
    typealias ProjectedCostProvider = @Sendable (UUID) async -> Double?

    /// Resolves projection-policy-derived context budget for a conversation.
    typealias ProjectionBudgetProvider = @Sendable (UUID) async -> ConversationContextBudget?

    static func build(
        conversationID: UUID,
        conversation: APILayerConversationManaging,
        runtime: APILayerChatRuntimeManaging?,
        poolStateProvider: PoolStateProvider? = nil,
        activeCallProvider: ActiveCallProvider? = nil,
        projectedCostProvider: ProjectedCostProvider? = nil,
        projectionBudgetProvider: ProjectionBudgetProvider? = nil,
        orchestrationOverride: ConversationOrchestrationState? = nil
    ) async -> ConversationStatePayload {
        let sessionSelected = false
        guard let row = await conversation.apiGetConversation(id: conversationID) else {
            return ConversationStatePayload.deleted(conversationID: conversationID)
        }

        let orchestration: ConversationOrchestrationState?
        if let orchestrationOverride {
            orchestration = orchestrationOverride
        } else {
            orchestration = await conversation.apiSnapshotOrchestrationState(conversationID: conversationID)
        }
        let replayActive = await runtime?.apiIsConversationReplayActive(conversationID: conversationID) ?? false

        let poolModelState: ModelStatePayload?
        if let provider = poolStateProvider {
            poolModelState = await provider(row.model.id)
        } else {
            poolModelState = nil
        }

        let activeCall = await activeCallProvider?(conversationID)
        let projectedCostUSD = await projectedCostProvider?(conversationID)
        let projectionBudget = await projectionBudgetProvider?(conversationID)
        let contextBudget = makeContextBudget(
            projectionBudget: projectionBudget,
            orchestration: orchestration
        )

        return ConversationStatePayload(
            conversationID: conversationID,
            exists: true,
            sessionSelected: sessionSelected,
            topic: row.topic,
            interactionMode: row.interactionMode,
            modeProfileID: row.modeProfileID,
            modelID: row.model.id,
            modelName: row.model.modelName,
            messageCount: row.messages.count,
            updatedAt: row.updatedAt,
            orchestration: orchestration,
            replayActive: replayActive,
            poolModelState: poolModelState,
            activeModelID: activeCall?.modelID,
            activeCallID: activeCall?.callID,
            contextBudget: contextBudget,
            projectedCostUSD: projectedCostUSD,
            lifecycle: row.lifecycle,
            parentConversationID: row.parentConversationID,
            tags: row.tags.isEmpty ? nil : row.tags,
            resourceBudgetSnapshot: row.budgetSnapshot,
            branchChildren: row.branchChildren.isEmpty ? nil : row.branchChildren,
            resourceRunStatus: row.resourceRunStatus,
            currentRunID: row.currentRunID,
            attachmentsCatalog: row.attachmentsCatalog.isEmpty ? nil : row.attachmentsCatalog
        )
    }

    /// Derives ``ConversationContextBudget`` with projection-policy precedence for
    /// `remainingTokens`, while preserving orchestration fallback when projection data is absent.
    private static func makeContextBudget(
        projectionBudget: ConversationContextBudget?,
        orchestration: ConversationOrchestrationState?
    ) -> ConversationContextBudget? {
        let limit = projectionBudget?.contextLimitTokens ?? orchestration?.contextLimitTokens
        let prompt = projectionBudget?.promptTokens ?? orchestration?.promptTokens
        let remaining = projectionBudget?.remainingTokens ?? orchestration?.remainingContextTokens
        let cacheStablePrefixMessageCount = projectionBudget?.cacheStablePrefixMessageCount
        let cachePruningTTLSeconds = projectionBudget?.cachePruningTTLSeconds
        let compactionStrategy = projectionBudget?.compactionStrategy
        if limit == nil && prompt == nil && remaining == nil { return nil }
        return ConversationContextBudget(
            contextLimitTokens: limit,
            promptTokens: prompt,
            remainingTokens: remaining,
            cacheStablePrefixMessageCount: cacheStablePrefixMessageCount,
            cachePruningTTLSeconds: cachePruningTTLSeconds,
            compactionStrategy: compactionStrategy
        )
    }
}
