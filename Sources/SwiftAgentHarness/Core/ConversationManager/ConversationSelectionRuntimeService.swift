import Foundation
import SwiftAgentKit

/// Active conversation selection mirror, message-stream bridge, and selection-scoped runtime helpers.
actor ConversationSelectionRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let persistenceDomain: ConversationPersistenceDomain
    private let skillActivation: SkillActivationService
    private let sessionProjection: SessionProjectionAccessing
    private let contextProjection: ContextProjectionService
    private let registryOwnerAccountScope: @Sendable () -> UUID?
    private let tenancyPolicy: TenancyPolicySettings

    private(set) var currentConversationID: UUID?
    private(set) var currentMessages: [Message] = []
    private var messageStreamContinuation: AsyncStream<[Message]>.Continuation?
    private var testingPreRunStateSendHook: (@Sendable (ModelConversation) async -> Void)?

    init(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain,
        skillActivation: SkillActivationService,
        sessionProjection: SessionProjectionAccessing,
        contextProjection: ContextProjectionService,
        registryOwnerAccountScope: @escaping @Sendable () -> UUID?,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.deps = deps
        self.persistenceDomain = persistenceDomain
        self.skillActivation = skillActivation
        self.sessionProjection = sessionProjection
        self.contextProjection = contextProjection
        self.registryOwnerAccountScope = registryOwnerAccountScope
        self.tenancyPolicy = tenancyPolicy
    }

    func currentConversation() async -> ModelConversation? {
        guard let currentConversationID else { return nil }
        return await persistenceDomain.modelConversation(id: currentConversationID)
    }

    func projectedMessages(for conversation: ModelConversation) async -> [Message] {
        await sessionProjection.projectedMessages(for: conversation)
    }

    func shouldMirrorSelectionToGlobalChatState() -> Bool {
        APISessionContext.connectionNamespace == nil
    }

    func selectConversation(conversationID: UUID) async throws {
        guard let conv = await persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard await isSelectionAccessible(conv) else {
            throw ConversationServiceError.conversationNotFound
        }

        if shouldMirrorSelectionToGlobalChatState() {
            if let previousID = currentConversationID, previousID != conversationID {
                try await skillActivation.persistSkillLoaderStateIntoConversationMetadata(previousID)
            }
            currentConversationID = conversationID
            setCurrentMessages(await sessionProjection.projectedMessages(for: conv))
        }

        try await skillActivation.restoreSkillLoader(for: conversationID)
    }

    func reselectAfterDelete(deletedConversationID: UUID) async throws {
        guard currentConversationID == deletedConversationID else { return }
        if let conversation = await persistenceDomain.firstConversation(excluding: deletedConversationID) {
            try await selectConversation(conversationID: conversation.id)
        } else {
            currentConversationID = nil
            setCurrentMessages([])
        }
    }

    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {
        guard conversationID == currentConversationID else { return }
        setCurrentMessages(await sessionProjection.projectedMessages(for: conversation))
    }

    func setCurrentMessagesProjection(for conversation: ModelConversation) async {
        guard conversation.id == currentConversationID else { return }
        setCurrentMessages(await sessionProjection.projectedMessages(for: conversation))
    }

    func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {
        guard conversationID == currentConversationID else { return }
        setCurrentMessages(messages)
    }

    func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) {
        messageStreamContinuation?.finish()
        messageStreamContinuation = continuation
        continuation.yield(initial)
    }

    func cancelMessageStreamBridge() {
        messageStreamContinuation?.finish()
        messageStreamContinuation = nil
    }

    func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) -> HarnessRuntimeSession.Configuration {
        var out = configuration
        out.inputTrustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(configuration.inputTrustRaw)
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: out.inputTrustRaw,
                unknownFallback: deps.trustPolicyConfiguration.safeDefaultClass
            )
        out.resolvedInputTrustClass = trustClass
        if deps.trustPolicyConfiguration.shouldGateExecution(for: trustClass) {
            out.enableTools = false
            out.enableAgents = false
        }
        return out
    }

    func transformedTurns(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn]
    ) -> [ConversationTurn] {
        ConversationTurnTransformProcessor().transform(
            messages: messages,
            interactionMode: interactionMode,
            previousTurns: previousTurns
        )
    }

    func runtimeSessionLaneKey(conversationID: UUID) async -> String {
        if let owner = await persistenceDomain.modelConversation(id: conversationID)?.ownerAccountID ?? registryOwnerAccountScope() {
            return "session:\(owner.uuidString.lowercased())"
        }
        return "session:\(conversationID.uuidString.lowercased())"
    }

    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID? = nil
    ) -> ConversationServiceError {
        switch admissionError {
        case .sessionLaneBusy(let activeRunID):
            return .conversationRunInProgress(
                conversationID: conversationID,
                activeRunID: activeRunID ?? activeRuntimeRunIDOverride ?? fallbackRunID
            )
        case .globalMainLaneAtCapacity(let limit):
            return .runtimeLaneUnavailable(reason: "global_main_lane_capacity_reached:\(limit)")
        case .globalSubagentLaneAtCapacity(let limit):
            return .runtimeLaneUnavailable(reason: "global_subagent_lane_capacity_reached:\(limit)")
        case .parentFanoutExceeded(let limit):
            return .runtimeLaneUnavailable(reason: "parent_fanout_limit_reached:\(limit)")
        }
    }

    func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async {
        guard let remaining = await contextProjection.projectionContextBudgetForState(conversationID: conversationID)?.remainingTokens else {
            return
        }
        do {
            try await persistenceDomain.persistBudgetSnapshot(
                conversationID: conversationID,
                snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: remaining)
            )
        } catch {
            deps.logger?.error("[ConversationSelectionRuntimeService] resource budget hint invalidation persistence failed: \(error)")
        }
    }

    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {
        if let hook = testingPreRunStateSendHook {
            await hook(conversation)
        }
    }

    func testing_setPreRunStateSendHook(_ hook: (@Sendable (ModelConversation) async -> Void)?) {
        testingPreRunStateSendHook = hook
    }

    func testing_setCurrentConversationID(_ id: UUID?) {
        currentConversationID = id
    }

    private func setCurrentMessages(_ messages: [Message]) {
        currentMessages = messages
        messageStreamContinuation?.yield(messages)
    }

    private func isSelectionAccessible(_ target: ModelConversation) async -> Bool {
        let scope = ConversationScope.current
        let callerConversation: ModelConversation?
        if let callerID = scope?.selfID {
            callerConversation = await persistenceDomain.modelConversation(id: callerID)
        } else {
            callerConversation = nil
        }
        let ownerScope = ToolConversationAccessPolicy.resolveOwnerScope(
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations,
            authenticatedOwnerAccountID: APISessionContext.authenticatedOwnerAccountID,
            callerConversation: callerConversation,
            registryOwnerAccountID: APISessionContext.authenticatedOwnerAccountID ?? registryOwnerAccountScope()
        )
        let callerLineageRoot: UUID?
        if let callerConversation {
            callerLineageRoot = await lineageRoot(for: callerConversation)
        } else {
            callerLineageRoot = nil
        }
        let targetLineageRoot = await lineageRoot(for: target)
        return ToolConversationAccessPolicy.isConversationAccessible(
            target: target,
            callerScope: scope,
            ownerScope: ownerScope,
            callerLineageRoot: callerLineageRoot,
            targetLineageRoot: targetLineageRoot,
            strictTenancy: tenancyPolicy.requireAuthenticatedOwnerOnMutations
        )
    }

    private func lineageRoot(for conversation: ModelConversation) async -> UUID {
        await ToolConversationAccessPolicy.lineageRoot(for: conversation) { id in
            await self.persistenceDomain.modelConversation(id: id)
        }
    }
}
