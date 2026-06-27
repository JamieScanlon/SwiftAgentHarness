import Foundation

/// Delivers block/preview/final streaming output to a channel outbound adapter.
public struct ChannelStreamingSurfaceSink: StreamingSurfaceSink {
    let outbound: any ChannelOutboundAdapting
    let threading: (any ChannelThreadingAdapting)?
    let target: ChannelDeliveryTarget
    let verboseDetailThread: Bool
    let retryingSender: ChannelRetryingSender

    public init(
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

    public func sendBlock(_ text: String) async {
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

    public func sendFinal(_ payload: StreamingFinalPayload) async {
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

    public func emitCancellation(_ notice: CancellationNotice) async {
        await sendBlock(notice.marker)
    }
}
