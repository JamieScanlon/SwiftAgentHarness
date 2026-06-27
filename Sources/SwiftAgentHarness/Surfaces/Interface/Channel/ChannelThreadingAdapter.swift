import Foundation

public struct DefaultChannelThreadingAdapter: ChannelThreadingAdapting {
    public init() {}

    public func deliveryTarget(
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
