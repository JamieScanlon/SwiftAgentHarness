import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

public struct TriggerDelegatedCompletionHandoff: Sendable {
    private let runRegistry: TriggerDelegatedRunRegistry
    private let outputRouter: TriggerSymmetricOutputRouter
    private let resolveParentConversation: @Sendable (UUID) async -> (parentID: UUID, metadata: JSON?)?
    private let lastAssistantText: @Sendable (UUID) async -> String?
    private let logger: Logger?

    init(
        runRegistry: TriggerDelegatedRunRegistry,
        outputRouter: TriggerSymmetricOutputRouter,
        resolveParentConversation: @escaping @Sendable (UUID) async -> (parentID: UUID, metadata: JSON?)?,
        lastAssistantText: @escaping @Sendable (UUID) async -> String?,
        logger: Logger? = nil
    ) {
        self.runRegistry = runRegistry
        self.outputRouter = outputRouter
        self.resolveParentConversation = resolveParentConversation
        self.lastAssistantText = lastAssistantText
        self.logger = logger
    }

    func handle(_ event: SubAgentPendingCompletionEvent) async -> Bool {
        let childID = event.conversationID
        guard let record = await runRegistry.record(forChildConversationID: childID) else {
            if let parent = await resolveParentConversation(childID),
               TriggerHostConversationMetadata.isTriggerHost(parent.metadata),
               let trigger = TriggerHostConversationMetadata.triggerFromFingerprint(parent.metadata) {
                return await deliverFromHostParent(
                    trigger: trigger,
                    childID: childID,
                    event: event,
                    parentID: parent.parentID
                )
            }
            return false
        }
        return await deliverRegistered(record: record, event: event)
    }

    private func deliverRegistered(
        record: TriggerDelegatedRunRecord,
        event: SubAgentPendingCompletionEvent
    ) async -> Bool {
        let announceID = event.completion.handleID
        guard await runRegistry.markDelivered(
            triggerID: record.trigger.id,
            childSessionID: record.childConversationID,
            announceID: announceID
        ) else {
            return true
        }
        let status: TriggerCompletionStatus = event.completion.result.success ? .completed : .failed
        let text = await resolvedResultText(childID: record.childConversationID, event: event)
        let result = TriggerCompletionResult(
            status: status,
            text: text,
            childSessionID: record.childConversationID,
            announceID: announceID
        )
        do {
            try await outputRouter.deliverCompletion(trigger: record.trigger, result: result)
        } catch {
            logger?.warning("[TriggerDelegatedCompletion] delivery failed: \(error)")
        }
        return true
    }

    private func deliverFromHostParent(
        trigger: HarnessTrigger,
        childID: UUID,
        event: SubAgentPendingCompletionEvent,
        parentID: UUID
    ) async -> Bool {
        let announceID = event.completion.handleID
        guard await runRegistry.markDelivered(
            triggerID: trigger.id,
            childSessionID: childID,
            announceID: announceID
        ) else {
            return true
        }
        let status: TriggerCompletionStatus = event.completion.result.success ? .completed : .failed
        let text = await resolvedResultText(childID: childID, event: event)
        let result = TriggerCompletionResult(
            status: status,
            text: text,
            childSessionID: childID,
            announceID: announceID
        )
        do {
            try await outputRouter.deliverCompletion(trigger: trigger, result: result)
        } catch {
            logger?.warning("[TriggerDelegatedCompletion] host delivery failed: \(error)")
        }
        _ = parentID
        return true
    }

    private func resolvedResultText(childID: UUID, event: SubAgentPendingCompletionEvent) async -> String {
        if event.completion.result.success {
            let fromCompletion = TriggerCompletionTextPolicy.normalizedAssistantText(event.completion.result.content)
            if !fromCompletion.isEmpty {
                return fromCompletion
            }
        }
        if let assistant = await lastAssistantText(childID) {
            return TriggerCompletionTextPolicy.normalizedAssistantText(assistant)
        }
        if event.completion.result.success {
            return ""
        }
        return event.completion.result.error ?? "delegated trigger run failed"
    }
}
