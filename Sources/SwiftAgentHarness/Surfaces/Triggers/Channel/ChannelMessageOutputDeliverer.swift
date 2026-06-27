import Foundation

struct ChannelMessageOutputDeliverer: MessageOutputDelivering {
    let pluginLookup: @Sendable (ChannelId) async -> ChannelPlugin?
    let retryingSender: ChannelRetryingSender

    init(
        pluginLookup: @escaping @Sendable (ChannelId) async -> ChannelPlugin?,
        retryingSender: ChannelRetryingSender = ChannelRetryingSender()
    ) {
        self.pluginLookup = pluginLookup
        self.retryingSender = retryingSender
    }

    func deliver(
        presentation: MessagePresentation,
        conversationID: UUID,
        metadata: MessageOutputDeliveryMetadata
    ) async {
        guard let surface = metadata.originSurface,
              let channel = ChannelId(rawValue: surface),
              let plugin = await pluginLookup(channel) else {
            return
        }
        let target = ChannelDeliveryTarget(
            chatId: metadata.chatId ?? "",
            threadId: metadata.threadId,
            replyToMessageId: nil
        )
        let payload = plugin.outbound.renderPresentation(presentation)
        _ = await retryingSender.send {
            await plugin.outbound.sendPayload(payload, target: target)
        }
    }
}

struct ChannelApprovalCapabilityAdapter: ChannelApprovalCapabilityAdapting {
    let outbound: any ChannelOutboundAdapting

    func deliverApproval(
        presentation: ApprovalPresentation,
        approvalID: String,
        command: String,
        target: ChannelDeliveryTarget
    ) async -> ChannelSendResult {
        let messagePresentation = presentation.asMessagePresentation(title: nil)
        let card = ChannelOutboundApprovalCard(
            approvalID: approvalID,
            title: messagePresentation.title ?? "Approval required",
            command: command,
            description: messagePresentation.textFallback(),
            actions: presentation.buttons.map { ChannelOutboundApprovalAction(id: $0.id, label: $0.label) }
        )
        let fallbackText = presentation.textFallback(approvalID: approvalID)
        let payload = ChannelRenderedPayload(text: fallbackText, approvalCard: card)
        return await outbound.sendPayload(payload, target: target)
    }
}
