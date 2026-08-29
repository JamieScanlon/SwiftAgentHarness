import Foundation

enum ScheduledTaskTriggerBuilder {
    static func makeTrigger(from task: ScheduledTask, missed: Bool = false, fireTimestampMs: Int64? = nil) -> HarnessTrigger {
        var payload = task.payloadText
        if missed {
            payload = "[missed] " + payload
        }
        // Honor the stored routing mode: it was resolved once, at registration, from the caller's
        // explicit choice. The only override left is structural — threading needs a target, and a
        // row without one has to fall back rather than route nowhere.
        let routingMode: TriggerRoutingMode
        switch task.routingMode {
        case .delegated:
            routingMode = .delegated
        case .threaded:
            routingMode = task.conversationID == nil ? .isolated : .threaded
        case .isolated:
            // A stored `.isolated` that still carries a target conversation is a row written before
            // routing was resolved at registration, when `.isolated` was merely the struct default
            // and the effective mode was inferred from the target. Honoring it literally would
            // re-home those tasks into a different session key and lose their history.
            routingMode = task.conversationID == nil ? .isolated : .threaded
        }
        let ts = fireTimestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let base = HarnessTrigger(
            id: "\(task.id):\(ts)",
            source: .cron,
            sourceMetadata: originMetadata(for: task).merging([
                "cronJobId": task.id,
                "payloadKind": task.payloadKind.rawValue,
                "title": task.title ?? task.id,
            ]) { _, new in new },
            payload: payload,
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: task.permanent ? .system : .user, id: task.id),
            trust: task.trust,
            enableTools: task.payloadKind == .agentTurn,
            enableAgents: task.payloadKind == .agentTurn,
            routingMode: routingMode
        )
        var trigger = TriggerIngressMetadata.enrich(
            base,
            routingMode: routingMode,
            delegate: task.delegate,
            deliveryWebhookURL: task.deliveryWebhookURL,
            delivery: task.delivery.rawValue
        )
        if let conversationID = task.conversationID, routingMode == .threaded {
            var metadata = trigger.sourceMetadata
            metadata["conversationID"] = conversationID
            if let ownerAccountID = task.ownerAccountID {
                metadata["ownerAccountID"] = ownerAccountID.uuidString
            }
            if let createdBy = task.createdByConversationID {
                metadata["createdByConversationID"] = createdBy.uuidString
            }
            trigger.sourceMetadata = metadata
        }
        if let correlation = task.correlation {
            trigger.correlation = correlation
        }
        return trigger
    }

    /// The originating chat, captured at registration time.
    ///
    /// A fired trigger has no live session, so this is the only way `announce` delivery finds the
    /// human who asked for it. Namespaced under `origin*` so it cannot be confused with the
    /// `channel`/`chatId` keys a genuine channel trigger carries.
    private static func originMetadata(for task: ScheduledTask) -> [String: String] {
        guard let origin = task.origin else { return [:] }
        var metadata: [String: String] = [:]
        if let channel = origin.channel { metadata["originChannel"] = channel }
        if let chatID = origin.chatID { metadata["originChatId"] = chatID }
        if let threadID = origin.threadID { metadata["originThreadId"] = threadID }
        if let accountID = origin.accountID { metadata["originAccountId"] = accountID }
        if let conversationID = origin.conversationID {
            metadata["originConversationID"] = conversationID.uuidString
        }
        return metadata
    }
}
