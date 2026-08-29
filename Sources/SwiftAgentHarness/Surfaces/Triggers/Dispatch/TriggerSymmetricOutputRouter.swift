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
        let outcome = await sendToChannel(
            channelRaw: trigger.sourceMetadata["channel"],
            chatID: trigger.sourceMetadata["chatId"] ?? "",
            threadID: trigger.sourceMetadata["threadId"],
            replyToMessageID: trigger.sourceMetadata["platformMessageId"],
            text: result.text
        )
        recordAudit(trigger: trigger, result: result, delivery: "channel:\(outcome)")
    }

    /// Shared channel egress for inbound channel triggers and for cron `announce` delivery back to
    /// the chat a task was registered from.
    private func sendToChannel(
        channelRaw: String?,
        chatID: String,
        threadID: String?,
        replyToMessageID: String?,
        text: String
    ) async -> String {
        guard let channelRaw,
              let channel = ChannelId(rawValue: channelRaw),
              let plugin = await channelRegistry.plugin(for: channel) else {
            return "missing-plugin"
        }
        guard !chatID.isEmpty else { return "missing-chat" }
        let target = ChannelDeliveryTarget(
            chatId: chatID,
            threadId: threadID,
            replyToMessageId: replyToMessageID
        )
        let presentation = MessagePresentation(blocks: [.text(text)])
        let payload = plugin.outbound.renderPresentation(presentation)
        let sendResult = await ChannelRetryingSender().send {
            await plugin.outbound.sendPayload(payload, target: target)
        }
        return String(describing: sendResult)
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
            try await announceCron(trigger: trigger, result: result)
        default:
            recordAudit(trigger: trigger, result: result, delivery: "cron-none")
        }
    }

    /// Deliver a budget breach notice to the owner through the origin channel captured at
    /// registration. Falls back to the audit log when the source has no addressable origin.
    func deliverBudgetNotice(_ notice: TriggerBudgetBreachNotice) async {
        let outcome: String
        if let channelRaw = notice.trigger.sourceMetadata["originChannel"] {
            outcome = await sendToChannel(
                channelRaw: channelRaw,
                chatID: notice.trigger.sourceMetadata["originChatId"] ?? "",
                threadID: notice.trigger.sourceMetadata["originThreadId"],
                replyToMessageID: nil,
                text: notice.message
            )
        } else {
            outcome = "no-origin"
        }
        var entry = TriggerAuditEntry.from(trigger: notice.trigger, decision: .overBudget, sessionID: nil)
        entry.triggerID = "budget:\(notice.rung.rawValue):\(notice.scopeKey):\(notice.windowKey):\(outcome)"
        auditLog.record(entry)
    }

    /// Deliver a scheduled task's answer back to whoever asked for it.
    ///
    /// Two shapes, decided by the origin captured at registration:
    /// - a chat channel — send through that channel's plugin, into the original thread;
    /// - an in-harness conversation — nothing to do here. A threaded run already produced its
    ///   answer *inside* that conversation, so re-delivering would double-post.
    private func announceCron(trigger: HarnessTrigger, result: TriggerCompletionResult) async throws {
        if let channelRaw = trigger.sourceMetadata["originChannel"] {
            let outcome = await sendToChannel(
                channelRaw: channelRaw,
                chatID: trigger.sourceMetadata["originChatId"] ?? "",
                threadID: trigger.sourceMetadata["originThreadId"],
                replyToMessageID: nil,
                text: result.text
            )
            recordAudit(trigger: trigger, result: result, delivery: "cron-announce-channel:\(outcome)")
            return
        }
        if trigger.routingMode == .threaded {
            recordAudit(trigger: trigger, result: result, delivery: "cron-announce-threaded")
            return
        }
        // Isolated run with no channel origin: there is no addressable target. Audited rather than
        // silently dropped so "my reminder never arrived" is diagnosable.
        logger?.warning("[TriggerOutput] cron announce has no delivery target trigger=\(trigger.id)")
        recordAudit(trigger: trigger, result: result, delivery: "cron-announce-no-target")
    }

    private func recordAudit(trigger: HarnessTrigger, result: TriggerCompletionResult, delivery: String) {
        var entry = TriggerAuditEntry.from(trigger: trigger, decision: .admitted, sessionID: result.childSessionID)
        entry.triggerID = "\(trigger.id):completion:\(delivery)"
        auditLog.record(entry)
    }
}
