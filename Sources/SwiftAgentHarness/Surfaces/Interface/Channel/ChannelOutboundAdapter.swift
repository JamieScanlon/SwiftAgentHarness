import Foundation

/// Thin alias onto the shared filter.
///
/// The degradation rule (text floor always, native blocks only where declared) is a
/// property of the surface contract, not of channels — keeping a second copy here is how
/// the two surfaces drift apart.
enum ChannelPresentationRenderer {
    static func render(
        _ presentation: MessagePresentation,
        capabilities: ChannelPresentationCapabilities
    ) -> ChannelRenderedPayload {
        SurfacePresentationFilter.render(presentation, capabilities: capabilities)
    }

    static func textFallback(from presentation: MessagePresentation) -> String {
        presentation.textFallback()
    }

    static func nativeBlocks(
        from blocks: [MessageBlock],
        capabilities: ChannelPresentationCapabilities
    ) -> [MessageBlock] {
        SurfacePresentationFilter.nativeBlocks(from: blocks, capabilities: capabilities)
    }
}

public struct DefaultChannelOutboundAdapter: ChannelOutboundAdapting {
    let listener: any ChannelOutboundListening
    let chunkLimit: Int
    public let presentationCapabilities: ChannelPresentationCapabilities

    public var textChunkLimit: Int { chunkLimit }

    public init(
        listener: any ChannelOutboundListening,
        chunkLimit: Int = 4000,
        presentationCapabilities: ChannelPresentationCapabilities = .mockRich
    ) {
        self.listener = listener
        self.chunkLimit = chunkLimit
        self.presentationCapabilities = presentationCapabilities
    }

    public func renderPresentation(_ presentation: MessagePresentation) -> ChannelRenderedPayload {
        ChannelPresentationRenderer.render(presentation, capabilities: presentationCapabilities)
    }

    public func sendPayload(_ payload: ChannelRenderedPayload, target: ChannelDeliveryTarget) async -> ChannelSendResult {
        if let richPresentation = payload.richPresentation {
            return await listener.send(
                ChannelOutboundMessage(
                    chatId: target.chatId,
                    threadId: target.threadId,
                    text: payload.text,
                    replyToMessageId: target.replyToMessageId,
                    approvalCard: payload.approvalCard,
                    richPresentation: richPresentation
                )
            )
        }
        let chunks = BlockChunker.split(text: payload.text, maxChars: textChunkLimit)
        var lastResult: ChannelSendResult = .sent(messageId: nil)
        for chunk in chunks {
            lastResult = await listener.send(
                ChannelOutboundMessage(
                    chatId: target.chatId,
                    threadId: target.threadId,
                    text: chunk,
                    replyToMessageId: target.replyToMessageId,
                    approvalCard: payload.approvalCard
                )
            )
            if case .failed = lastResult { return lastResult }
        }
        return lastResult
    }
}

extension BlockChunker {
    static func split(text: String, maxChars: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        if text.count <= maxChars { return [text] }
        var chunker = BlockChunker(
            config: ChunkerConfig(minChars: 1, maxChars: maxChars, textChunkLimit: maxChars),
            breakPreference: .paragraph
        )
        var chunks = chunker.ingest(text)
        chunks.append(contentsOf: chunker.flush())
        return chunks.isEmpty ? [String(text.prefix(maxChars))] : chunks
    }
}
