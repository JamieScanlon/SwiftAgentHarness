import Foundation

protocol TriggerOutputRouting: Sendable {
    func routeResponse(trigger: HarnessTrigger, responseText: String, plugin: ChannelPlugin) async -> ChannelSendResult
}

struct TriggerOutputRouter: TriggerOutputRouting {
    func routeResponse(
        trigger: HarnessTrigger,
        responseText: String,
        plugin: ChannelPlugin
    ) async -> ChannelSendResult {
        let target = ChannelDeliveryTarget(
            chatId: trigger.sourceMetadata["chatId"] ?? "",
            threadId: trigger.sourceMetadata["threadId"],
            replyToMessageId: trigger.sourceMetadata["platformMessageId"]
        )
        let payload = plugin.outbound.renderPresentation(
            MessagePresentation(blocks: [.text(responseText)])
        )
        return await plugin.outbound.sendPayload(payload, target: target)
    }
}
