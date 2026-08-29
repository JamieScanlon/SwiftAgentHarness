import Foundation

// Channel-first names retained as aliases of the shared surface vocabulary. Nothing about
// a rendered presentation is channel-specific, so the types now live in
// `Interface/SurfacePlugin.swift` and both surfaces use one contract.
public typealias ChannelOutboundApprovalAction = SurfaceApprovalAction
public typealias ChannelOutboundApprovalCard = SurfaceApprovalCard
public typealias ChannelOutboundRichPresentation = SurfaceRichPresentation

public struct ChannelOutboundMessage: Sendable, Equatable {
    public var chatId: String
    public var threadId: String?
    public var text: String
    public var replyToMessageId: String?
    public var approvalCard: ChannelOutboundApprovalCard?
    public var richPresentation: ChannelOutboundRichPresentation?

    public init(
        chatId: String,
        threadId: String? = nil,
        text: String,
        replyToMessageId: String? = nil,
        approvalCard: ChannelOutboundApprovalCard? = nil,
        richPresentation: ChannelOutboundRichPresentation? = nil
    ) {
        self.chatId = chatId
        self.threadId = threadId
        self.text = text
        self.replyToMessageId = replyToMessageId
        self.approvalCard = approvalCard
        self.richPresentation = richPresentation
    }
}

public enum ChannelSendResult: Sendable, Equatable {
    case sent(messageId: String?)
    case failed(code: String, message: String)
}
