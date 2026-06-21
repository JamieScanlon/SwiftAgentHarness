import Foundation

enum ScheduledTaskTriggerBuilder {
    static func makeTrigger(from task: ScheduledTask, missed: Bool = false, fireTimestampMs: Int64? = nil) -> HarnessTrigger {
        var payload = task.payloadText
        if missed {
            payload = "[missed] " + payload
        }
        let routingMode: TriggerRoutingMode
        if task.routingMode == .delegated {
            routingMode = .delegated
        } else {
            routingMode = task.conversationID == nil ? .isolated : .threaded
        }
        let ts = fireTimestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let base = HarnessTrigger(
            id: "\(task.id):\(ts)",
            source: .cron,
            sourceMetadata: [
                "cronJobId": task.id,
                "payloadKind": task.payloadKind.rawValue,
                "title": task.title ?? task.id,
            ],
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
            trigger.sourceMetadata = metadata
        }
        return trigger
    }
}
