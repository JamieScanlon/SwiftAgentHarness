import Foundation

struct ChannelOutboundApprovalAction: Sendable, Equatable {
    var id: String
    var label: String
}

struct ChannelOutboundApprovalCard: Sendable, Equatable {
    var approvalID: String
    var title: String
    var command: String
    var description: String
    var actions: [ChannelOutboundApprovalAction]
}

struct ChannelOutboundMessage: Sendable, Equatable {
    var chatId: String
    var threadId: String?
    var text: String
    var replyToMessageId: String?
    var approvalCard: ChannelOutboundApprovalCard?
}

enum ChannelSendResult: Sendable, Equatable {
    case sent(messageId: String?)
    case failed(code: String, message: String)
}
