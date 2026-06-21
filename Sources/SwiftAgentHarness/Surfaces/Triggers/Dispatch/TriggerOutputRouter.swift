import Foundation

protocol TriggerOutputRouting: Sendable {
    func routeResponse(trigger: HarnessTrigger, responseText: String, listener: any ChannelListener) async -> ChannelSendResult
}

struct TriggerOutputRouter: TriggerOutputRouting {
    func routeResponse(
        trigger: HarnessTrigger,
        responseText: String,
        listener: any ChannelListener
    ) async -> ChannelSendResult {
        let chatId = trigger.sourceMetadata["chatId"] ?? ""
        let threadId = trigger.sourceMetadata["threadId"]
        let replyTo = trigger.sourceMetadata["platformMessageId"]
        return await listener.send(
            ChannelOutboundMessage(
                chatId: chatId,
                threadId: threadId,
                text: responseText,
                replyToMessageId: replyTo
            )
        )
    }
}
