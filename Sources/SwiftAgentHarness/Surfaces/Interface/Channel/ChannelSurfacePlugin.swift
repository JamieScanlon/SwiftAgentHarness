import Foundation

/// Outbound slot: render portable presentations and deliver to the platform wire.
public protocol ChannelOutboundAdapting: Sendable {
    var presentationCapabilities: ChannelPresentationCapabilities { get }
    func renderPresentation(_ presentation: MessagePresentation) -> ChannelRenderedPayload
    func sendPayload(_ payload: ChannelRenderedPayload, target: ChannelDeliveryTarget) async -> ChannelSendResult
    var textChunkLimit: Int { get }
}

public struct ChannelPresentationCapabilities: Sendable, Equatable {
    public var supported: Bool
    public var buttons: Bool
    public var selects: Bool
    public var context: Bool
    public var divider: Bool

    public init(supported: Bool, buttons: Bool, selects: Bool, context: Bool, divider: Bool) {
        self.supported = supported
        self.buttons = buttons
        self.selects = selects
        self.context = context
        self.divider = divider
    }

    public static let mockRich = ChannelPresentationCapabilities(
        supported: true,
        buttons: true,
        selects: false,
        context: true,
        divider: true
    )
}

public struct ChannelRenderedPayload: Sendable, Equatable {
    public var text: String
    public var richPresentation: ChannelOutboundRichPresentation?
    public var approvalCard: ChannelOutboundApprovalCard?

    public init(
        text: String,
        approvalCard: ChannelOutboundApprovalCard? = nil,
        richPresentation: ChannelOutboundRichPresentation? = nil
    ) {
        self.text = text
        self.approvalCard = approvalCard
        self.richPresentation = richPresentation
    }
}

public struct ChannelDeliveryTarget: Sendable, Equatable {
    public var chatId: String
    public var threadId: String?
    public var replyToMessageId: String?

    public init(chatId: String, threadId: String? = nil, replyToMessageId: String? = nil) {
        self.chatId = chatId
        self.threadId = threadId
        self.replyToMessageId = replyToMessageId
    }
}

/// Threading slot: map platform thread ids onto delivery targets.
public protocol ChannelThreadingAdapting: Sendable {
    func deliveryTarget(
        chatId: String,
        threadId: String?,
        replyToMessageId: String?,
        verboseDetailThread: Bool
    ) -> ChannelDeliveryTarget
}

/// Heartbeat / liveness slot.
public protocol ChannelHeartbeatAdapting: Sendable {
    func sendTyping(chatId: String) async
}

/// Native approval delivery slot.
public protocol ChannelApprovalCapabilityAdapting: Sendable {
    func deliverApproval(
        presentation: ApprovalPresentation,
        approvalID: String,
        command: String,
        target: ChannelDeliveryTarget
    ) async -> ChannelSendResult
}

/// Optional media params for the shared `message` tool schema.
public protocol ChannelMessageToolDescribing: Sendable {
    func describeMessageTool() -> [MessageToolActionSchema]
}

public struct ChannelSurfaceMeta: Sendable, Equatable {
    public var platformIdentity: String
    public var transportKindRaw: String

    public init(platformIdentity: String, transportKindRaw: String) {
        self.platformIdentity = platformIdentity
        self.transportKindRaw = transportKindRaw
    }
}

/// Surface capability record for a messaging channel (outbound contract leaf).
public struct ChannelSurfacePlugin: Sendable {
    public var id: ChannelId
    public var meta: ChannelSurfaceMeta
    public var capabilities: ChannelCapabilities
    public var outbound: any ChannelOutboundAdapting
    public var threading: (any ChannelThreadingAdapting)?
    public var heartbeat: (any ChannelHeartbeatAdapting)?
    public var approvalCapability: (any ChannelApprovalCapabilityAdapting)?
    public var messageToolDescriptor: (any ChannelMessageToolDescribing)?
    public var streamingCapabilities: StreamingSurfaceCapabilities

    public init(
        id: ChannelId,
        meta: ChannelSurfaceMeta,
        capabilities: ChannelCapabilities,
        outbound: any ChannelOutboundAdapting,
        threading: (any ChannelThreadingAdapting)?,
        heartbeat: (any ChannelHeartbeatAdapting)?,
        approvalCapability: (any ChannelApprovalCapabilityAdapting)?,
        messageToolDescriptor: (any ChannelMessageToolDescribing)?,
        streamingCapabilities: StreamingSurfaceCapabilities
    ) {
        self.id = id
        self.meta = meta
        self.capabilities = capabilities
        self.outbound = outbound
        self.threading = threading
        self.heartbeat = heartbeat
        self.approvalCapability = approvalCapability
        self.messageToolDescriptor = messageToolDescriptor
        self.streamingCapabilities = streamingCapabilities
    }
}
