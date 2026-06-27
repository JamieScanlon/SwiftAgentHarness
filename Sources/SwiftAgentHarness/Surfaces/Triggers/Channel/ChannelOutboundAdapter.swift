import Foundation

enum ChannelPresentationRenderer {
    static func render(
        _ presentation: MessagePresentation,
        capabilities: ChannelPresentationCapabilities
    ) -> ChannelRenderedPayload {
        if capabilities.supported {
            return ChannelRenderedPayload(text: presentation.textFallback(), approvalCard: nil)
        }
        return ChannelRenderedPayload(text: presentation.textFallback(), approvalCard: nil)
    }

    static func textFallback(from presentation: MessagePresentation) -> String {
        presentation.textFallback()
    }
}

struct DefaultChannelOutboundAdapter: ChannelOutboundAdapting {
    let listener: any ChannelListener
    let chunkLimit: Int
    let presentationCapabilities: ChannelPresentationCapabilities

    var textChunkLimit: Int { chunkLimit }

    init(
        listener: any ChannelListener,
        chunkLimit: Int = 4000,
        presentationCapabilities: ChannelPresentationCapabilities = .mockRich
    ) {
        self.listener = listener
        self.chunkLimit = chunkLimit
        self.presentationCapabilities = presentationCapabilities
    }

    func renderPresentation(_ presentation: MessagePresentation) -> ChannelRenderedPayload {
        ChannelPresentationRenderer.render(presentation, capabilities: presentationCapabilities)
    }

    func sendPayload(_ payload: ChannelRenderedPayload, target: ChannelDeliveryTarget) async -> ChannelSendResult {
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
