import Foundation

/// Outbound slot: render portable presentations and deliver to the platform wire.
///
/// Refines the shared ``SurfacePresentationRendering`` contract — the rendering half is
/// common to every surface — and adds the channel-specific delivery half, which needs a
/// chat/thread target no other surface has.
public protocol ChannelOutboundAdapting: SurfacePresentationRendering {
    func sendPayload(_ payload: ChannelRenderedPayload, target: ChannelDeliveryTarget) async -> ChannelSendResult
}

/// Channel-first names retained as aliases of the shared surface vocabulary.
public typealias ChannelPresentationCapabilities = SurfacePresentationCapabilities
public typealias ChannelRenderedPayload = SurfaceRenderedPayload

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
public protocol ChannelMessageToolDescribing: SurfaceMessageToolDescribing {}

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


// MARK: - Uniform surface contract

/// Satisfies the shared ``SurfacePlugin`` contract without changing a single stored
/// property.
///
/// Extraction by conformance rather than restructuring: the channel surface is working
/// code with tests behind it, and reshaping its record to fit a newly-minted protocol
/// would risk a regression to buy nothing the computed accessors below don't already
/// deliver. `threading` and `heartbeat` stay off the shared contract deliberately — a
/// terminal has no honest implementation of either.
extension ChannelSurfacePlugin: SurfacePlugin {
    public var surfaceID: String { id.rawValue }

    public var surfaceMeta: SurfaceMeta {
        SurfaceMeta(displayName: meta.platformIdentity, kindRaw: meta.transportKindRaw)
    }

    public var surfaceCapabilities: SurfaceCapabilities {
        SurfaceCapabilities(
            richPresentation: outbound.presentationCapabilities.supported,
            nativeApprovalCards: capabilities.nativeApprovalCards,
            // All three rungs come from `supportedGranularities`, which states what the
            // surface *can* do. Mixing the configured `granularity` with the separate
            // `ChannelCapabilities` flags let a plugin report token and block streaming
            // simultaneously — an incoherent record for anyone switching on the rung.
            tokenStreaming: streamingCapabilities.supportedGranularities.contains(.tokenDelta),
            blockStreaming: streamingCapabilities.supportedGranularities.contains(.block),
            previewStreaming: streamingCapabilities.supportedGranularities.contains(.previewEdit),
            mediaAttachments: capabilities.mediaAttachments,
            threading: capabilities.threading,
            typingIndicators: capabilities.typingIndicators
        )
    }

    public var presentationRenderer: any SurfacePresentationRendering { outbound }

    public var surfaceMessageToolDescriptor: (any SurfaceMessageToolDescribing)? {
        messageToolDescriptor
    }
}
