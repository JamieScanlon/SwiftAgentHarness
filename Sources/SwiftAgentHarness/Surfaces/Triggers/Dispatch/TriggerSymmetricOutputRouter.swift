import Foundation
import Logging

protocol TriggerSymmetricOutputRouting: Sendable {
    func deliverCompletion(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws
}

struct TriggerSymmetricOutputRouter: TriggerSymmetricOutputRouting {
    private let channelRegistry: ChannelListenerRegistry
    private let auditLog: TriggerAuditLog
    private let webhookPost: @Sendable (String, WebhookOutboundPayload) async throws -> Int
    private let logger: Logger?

    init(
        channelRegistry: ChannelListenerRegistry,
        auditLog: TriggerAuditLog,
        webhookPost: @escaping @Sendable (String, WebhookOutboundPayload) async throws -> Int = { url, payload in
            try await WebhookOutboundDelivery.post(urlString: url, payload: payload)
        },
        logger: Logger? = nil
    ) {
        self.channelRegistry = channelRegistry
        self.auditLog = auditLog
        self.webhookPost = webhookPost
        self.logger = logger
    }

    func deliverCompletion(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws {
        if let reason = TriggerCompletionTextPolicy.suppressReason(for: result.text) {
            logger?.debug("[TriggerOutput] suppressed egress trigger=\(trigger.id) reason=\(reason)")
            recordAudit(trigger: trigger, result: result, delivery: "suppressed")
            return
        }
        switch trigger.source {
        case .channel:
            try await deliverChannel(trigger: trigger, result: result)
        case .webhook:
            try await deliverWebhook(trigger: trigger, result: result)
        case .cron:
            try await deliverCron(trigger: trigger, result: result)
        case .fileEvent, .api, .delegate:
            recordAudit(trigger: trigger, result: result, delivery: "audit-only")
        }
    }

    private func deliverChannel(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws {
        guard let channelRaw = trigger.sourceMetadata["channel"],
              let channel = ChannelId(rawValue: channelRaw),
              let plugin = await channelRegistry.plugin(for: channel) else {
            recordAudit(trigger: trigger, result: result, delivery: "channel-missing-plugin")
            return
        }
        let target = ChannelDeliveryTarget(
            chatId: trigger.sourceMetadata["chatId"] ?? "",
            threadId: trigger.sourceMetadata["threadId"],
            replyToMessageId: trigger.sourceMetadata["platformMessageId"]
        )
        let presentation = MessagePresentation(blocks: [.text(result.text)])
        let payload = plugin.outbound.renderPresentation(presentation)
        let sendResult = await ChannelRetryingSender().send {
            await plugin.outbound.sendPayload(payload, target: target)
        }
        recordAudit(trigger: trigger, result: result, delivery: "channel:\(String(describing: sendResult))")
    }

    private func deliverWebhook(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws {
        guard let url = trigger.sourceMetadata["deliveryWebhookURL"], !url.isEmpty else {
            recordAudit(trigger: trigger, result: result, delivery: "webhook-no-url")
            return
        }
        let payload = WebhookOutboundPayload(
            triggerID: trigger.id,
            routeName: trigger.sourceMetadata["routeName"] ?? "",
            status: result.status,
            text: result.text,
            childSessionID: result.childSessionID.uuidString
        )
        let statusCode = try await webhookPost(url, payload)
        recordAudit(trigger: trigger, result: result, delivery: "webhook:\(statusCode)")
    }

    private func deliverCron(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws {
        let delivery = trigger.sourceMetadata["delivery"] ?? ScheduledTaskDelivery.none.rawValue
        switch delivery {
        case ScheduledTaskDelivery.webhook.rawValue:
            guard let url = trigger.sourceMetadata["deliveryWebhookURL"], !url.isEmpty else {
                recordAudit(trigger: trigger, result: result, delivery: "cron-webhook-no-url")
                return
            }
            let payload = WebhookOutboundPayload(
                triggerID: trigger.id,
                routeName: trigger.sourceMetadata["cronJobId"] ?? "",
                status: result.status,
                text: result.text,
                childSessionID: result.childSessionID.uuidString
            )
            let statusCode = try await webhookPost(url, payload)
            recordAudit(trigger: trigger, result: result, delivery: "cron-webhook:\(statusCode)")
        case ScheduledTaskDelivery.announce.rawValue:
            recordAudit(trigger: trigger, result: result, delivery: "cron-announce")
        default:
            recordAudit(trigger: trigger, result: result, delivery: "cron-none")
        }
    }

    private func recordAudit(trigger: HarnessTrigger, result: TriggerCompletionResult, delivery: String) {
        var entry = TriggerAuditEntry.from(trigger: trigger, decision: .admitted, sessionID: result.childSessionID)
        entry.triggerID = "\(trigger.id):completion:\(delivery)"
        auditLog.record(entry)
    }
}
