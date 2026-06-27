import Foundation

public struct ChannelMessageOutputDeliverer: MessageOutputDelivering {
    let surfaceLookup: @Sendable (ChannelId) async -> ChannelSurfacePlugin?
    let retryingSender: ChannelRetryingSender

    public init(
        surfaceLookup: @escaping @Sendable (ChannelId) async -> ChannelSurfacePlugin?,
        retryingSender: ChannelRetryingSender = ChannelRetryingSender()
    ) {
        self.surfaceLookup = surfaceLookup
        self.retryingSender = retryingSender
    }

    public func deliver(
        presentation: MessagePresentation,
        conversationID: UUID,
        metadata: MessageOutputDeliveryMetadata
    ) async {
        guard let surfaceRaw = metadata.originSurface,
              let channel = ChannelId(rawValue: surfaceRaw),
              let surface = await surfaceLookup(channel) else {
            return
        }
        let target = ChannelDeliveryTarget(
            chatId: metadata.chatId ?? "",
            threadId: metadata.threadId,
            replyToMessageId: nil
        )
        let payload = surface.outbound.renderPresentation(presentation)
        _ = await retryingSender.send {
            await surface.outbound.sendPayload(payload, target: target)
        }
    }
}
