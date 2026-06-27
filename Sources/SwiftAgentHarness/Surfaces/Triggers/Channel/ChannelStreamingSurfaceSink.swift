import Foundation

/// Delivers block/preview/final streaming output to a channel outbound adapter.
struct ChannelStreamingSurfaceSink: StreamingSurfaceSink {
    let outbound: any ChannelOutboundAdapting
    let threading: (any ChannelThreadingAdapting)?
    let target: ChannelDeliveryTarget
    let verboseDetailThread: Bool
    let retryingSender: ChannelRetryingSender

    init(
        outbound: any ChannelOutboundAdapting,
        threading: (any ChannelThreadingAdapting)?,
        target: ChannelDeliveryTarget,
        verboseDetailThread: Bool = false,
        retryingSender: ChannelRetryingSender = ChannelRetryingSender()
    ) {
        self.outbound = outbound
        self.threading = threading
        self.target = target
        self.verboseDetailThread = verboseDetailThread
        self.retryingSender = retryingSender
    }

    func sendBlock(_ text: String) async {
        guard !text.isEmpty else { return }
        let deliveryTarget = threading?.deliveryTarget(
            chatId: target.chatId,
            threadId: target.threadId,
            replyToMessageId: target.replyToMessageId,
            verboseDetailThread: verboseDetailThread
        ) ?? target
        let payload = ChannelRenderedPayload(text: text, approvalCard: nil)
        _ = await retryingSender.send {
            await outbound.sendPayload(payload, target: deliveryTarget)
        }
    }

    func sendFinal(_ payload: StreamingFinalPayload) async {
        let deliveryTarget = threading?.deliveryTarget(
            chatId: target.chatId,
            threadId: target.threadId,
            replyToMessageId: target.replyToMessageId,
            verboseDetailThread: verboseDetailThread
        ) ?? target
        let rendered = ChannelRenderedPayload(text: payload.text, approvalCard: nil)
        _ = await retryingSender.send {
            await outbound.sendPayload(rendered, target: deliveryTarget)
        }
    }

    func emitCancellation(_ notice: CancellationNotice) async {
        await sendBlock(notice.marker)
    }
}

struct DefaultChannelThreadingAdapter: ChannelThreadingAdapting {
    func deliveryTarget(
        chatId: String,
        threadId: String?,
        replyToMessageId: String?,
        verboseDetailThread: Bool
    ) -> ChannelDeliveryTarget {
        if verboseDetailThread, threadId == nil {
            return ChannelDeliveryTarget(chatId: chatId, threadId: replyToMessageId, replyToMessageId: replyToMessageId)
        }
        return ChannelDeliveryTarget(chatId: chatId, threadId: threadId, replyToMessageId: replyToMessageId)
    }
}
