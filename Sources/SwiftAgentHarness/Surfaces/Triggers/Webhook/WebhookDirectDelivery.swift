import Foundation
import Logging

struct WebhookDirectDelivery: Sendable {
    let channelRegistry: any ChannelPluginLooking
    let webhookPost: @Sendable (String, Data) async throws -> Int
    let logger: Logger?

    init(
        channelRegistry: any ChannelPluginLooking,
        webhookPost: @escaping @Sendable (String, Data) async throws -> Int = { url, body in
            try await WebhookOutboundDelivery.postRawJSON(urlString: url, body: body)
        },
        logger: Logger? = nil
    ) {
        self.channelRegistry = channelRegistry
        self.webhookPost = webhookPost
        self.logger = logger
    }

    func deliver(route: WebhookRoute, rendered: String, extra: [String: String]) async -> WebhookDeliverOnlyOutcome {
        if let url = route.deliveryWebhookURL, !url.isEmpty {
            return await deliverWebhook(url: url, rendered: rendered)
        }
        guard let channel = ChannelId(rawValue: route.delivery) else {
            return .targetMissing
        }
        guard let plugin = await channelRegistry.plugin(for: channel) else {
            logger?.warning("[WebhookDirectDelivery] missing plugin channel=\(channel.rawValue) route=\(route.name)")
            return .targetMissing
        }
        let target = ChannelDeliveryTarget(
            chatId: extra["chatId"] ?? "",
            threadId: extra["threadId"],
            replyToMessageId: extra["replyToMessageId"]
        )
        let payload = ChannelRenderedPayload(text: rendered, approvalCard: nil)
        let result = await plugin.outbound.sendPayload(payload, target: target)
        switch result {
        case .sent:
            return .success
        case .failed(_, let message):
            return .deliveryFailed(reason: message)
        }
    }

    private func deliverWebhook(url: String, rendered: String) async -> WebhookDeliverOnlyOutcome {
        let body = (try? JSONSerialization.data(withJSONObject: ["text": rendered])) ?? Data(rendered.utf8)
        do {
            _ = try await webhookPost(url, body)
            return .success
        } catch {
            return .deliveryFailed(reason: String(describing: error))
        }
    }
}
