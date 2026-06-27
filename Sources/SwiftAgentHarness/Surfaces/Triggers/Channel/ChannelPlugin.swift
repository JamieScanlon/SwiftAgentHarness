import Foundation

/// Capability flags declared by a channel plugin.
public struct ChannelCapabilities: Sendable, Equatable, Codable {
    public var threading: Bool
    public var blockStreaming: Bool
    public var previewStreaming: Bool
    public var nativeApprovalCards: Bool
    public var typingIndicators: Bool
    public var reactions: Bool
    public var mediaAttachments: Bool

    public init(
        threading: Bool = false,
        blockStreaming: Bool = true,
        previewStreaming: Bool = false,
        nativeApprovalCards: Bool = false,
        typingIndicators: Bool = false,
        reactions: Bool = false,
        mediaAttachments: Bool = false
    ) {
        self.threading = threading
        self.blockStreaming = blockStreaming
        self.previewStreaming = previewStreaming
        self.nativeApprovalCards = nativeApprovalCards
        self.typingIndicators = typingIndicators
        self.reactions = reactions
        self.mediaAttachments = mediaAttachments
    }

    public static let mock = ChannelCapabilities(
        threading: true,
        blockStreaming: true,
        previewStreaming: true,
        nativeApprovalCards: true,
        typingIndicators: true
    )
}

/// Outbound slot: render portable presentations and deliver to the platform wire.
protocol ChannelOutboundAdapting: Sendable {
    var presentationCapabilities: ChannelPresentationCapabilities { get }
    func renderPresentation(_ presentation: MessagePresentation) -> ChannelRenderedPayload
    func sendPayload(_ payload: ChannelRenderedPayload, target: ChannelDeliveryTarget) async -> ChannelSendResult
    var textChunkLimit: Int { get }
}

struct ChannelPresentationCapabilities: Sendable, Equatable {
    var supported: Bool
    var buttons: Bool
    var selects: Bool
    var context: Bool
    var divider: Bool

    static let mockRich = ChannelPresentationCapabilities(
        supported: true,
        buttons: true,
        selects: false,
        context: true,
        divider: true
    )
}

struct ChannelRenderedPayload: Sendable, Equatable {
    var text: String
    var approvalCard: ChannelOutboundApprovalCard?
}

struct ChannelDeliveryTarget: Sendable, Equatable {
    var chatId: String
    var threadId: String?
    var replyToMessageId: String?
}

/// Threading slot: map platform thread ids onto delivery targets.
protocol ChannelThreadingAdapting: Sendable {
    func deliveryTarget(
        chatId: String,
        threadId: String?,
        replyToMessageId: String?,
        verboseDetailThread: Bool
    ) -> ChannelDeliveryTarget
}

/// Session grammar slot: resolve native ids to session keys and parent fallbacks.
protocol ChannelSessionGrammarAdapting: Sendable {
    func resolveSessionConversation(raw: ChannelSessionRawIdentity) -> ChannelSessionConversationResolution
}

struct ChannelSessionRawIdentity: Sendable, Equatable {
    var channel: ChannelId
    var accountId: String
    var chatId: String
    var threadId: String?
    var senderId: String
    var platformMessageId: String
}

struct ChannelSessionConversationResolution: Sendable, Equatable {
    var baseConversationKey: String
    var threadId: String?
    var parentFallbackCandidates: [String]
}

/// Security slot: inbound trust, allowlists, mention gating helpers.
protocol ChannelSecurityAdapting: Sendable {
    func classifyTrust(event: ChannelMessageEvent, config: ChannelListenerConfig) -> CommEnvelopeOriginTrust
    func redactLogIdentifier(_ value: String) -> String
}

/// Heartbeat / liveness slot.
protocol ChannelHeartbeatAdapting: Sendable {
    func sendTyping(chatId: String) async
}

/// Native approval delivery slot.
protocol ChannelApprovalCapabilityAdapting: Sendable {
    func deliverApproval(
        presentation: ApprovalPresentation,
        approvalID: String,
        command: String,
        target: ChannelDeliveryTarget
    ) async -> ChannelSendResult
}

/// Optional media params for the shared `message` tool schema.
protocol ChannelMessageToolDescribing: Sendable {
    func describeMessageTool() -> [MessageToolActionSchema]
}

/// Capability record for a messaging channel plugin.
struct ChannelPlugin: Sendable {
    var id: ChannelId
    var meta: ChannelPluginMeta
    var capabilities: ChannelCapabilities
    var config: ChannelListenerConfig
    var listener: any ChannelListener
    var outbound: any ChannelOutboundAdapting
    var threading: (any ChannelThreadingAdapting)?
    var sessionGrammar: any ChannelSessionGrammarAdapting
    var security: any ChannelSecurityAdapting
    var heartbeat: (any ChannelHeartbeatAdapting)?
    var approvalCapability: (any ChannelApprovalCapabilityAdapting)?
    var messageToolDescriptor: (any ChannelMessageToolDescribing)?
    var streamingCapabilities: StreamingSurfaceCapabilities
}

struct ChannelPluginMeta: Sendable, Equatable {
    var platformIdentity: String
    var transportKind: ChannelTransportKind
}
