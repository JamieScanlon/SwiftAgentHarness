import Foundation

public struct ChannelOutboundApprovalAction: Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ChannelOutboundApprovalCard: Sendable, Equatable {
    public var approvalID: String
    public var title: String
    public var command: String
    public var description: String
    public var actions: [ChannelOutboundApprovalAction]

    public init(
        approvalID: String,
        title: String,
        command: String,
        description: String,
        actions: [ChannelOutboundApprovalAction]
    ) {
        self.approvalID = approvalID
        self.title = title
        self.command = command
        self.description = description
        self.actions = actions
    }
}

public struct ChannelOutboundRichPresentation: Sendable, Equatable {
    public var title: String?
    public var tone: MessageTone?
    public var blocks: [MessageBlock]

    public init(title: String? = nil, tone: MessageTone? = nil, blocks: [MessageBlock]) {
        self.title = title
        self.tone = tone
        self.blocks = blocks
    }
}

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
