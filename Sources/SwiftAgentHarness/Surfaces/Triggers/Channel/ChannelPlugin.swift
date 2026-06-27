import Foundation

/// Assembled runtime channel plugin: Interface surface contract plus trigger inbound slots.
struct ChannelPlugin: Sendable {
    var surface: ChannelSurfacePlugin
    var config: ChannelListenerConfig
    var listener: any ChannelListener
    var security: any ChannelSecurityAdapting
    var sessionGrammar: any ChannelSessionGrammarAdapting

    init(
        surface: ChannelSurfacePlugin,
        config: ChannelListenerConfig,
        listener: any ChannelListener,
        security: any ChannelSecurityAdapting,
        sessionGrammar: any ChannelSessionGrammarAdapting
    ) {
        self.surface = surface
        self.config = config
        self.listener = listener
        self.security = security
        self.sessionGrammar = sessionGrammar
    }

    init(
        id: ChannelId,
        meta: ChannelSurfaceMeta,
        capabilities: ChannelCapabilities,
        config: ChannelListenerConfig,
        listener: any ChannelListener,
        outbound: any ChannelOutboundAdapting,
        threading: (any ChannelThreadingAdapting)?,
        sessionGrammar: any ChannelSessionGrammarAdapting,
        security: any ChannelSecurityAdapting,
        heartbeat: (any ChannelHeartbeatAdapting)?,
        approvalCapability: (any ChannelApprovalCapabilityAdapting)?,
        messageToolDescriptor: (any ChannelMessageToolDescribing)?,
        streamingCapabilities: StreamingSurfaceCapabilities
    ) {
        self.init(
            surface: ChannelSurfacePlugin(
                id: id,
                meta: meta,
                capabilities: capabilities,
                outbound: outbound,
                threading: threading,
                heartbeat: heartbeat,
                approvalCapability: approvalCapability,
                messageToolDescriptor: messageToolDescriptor,
                streamingCapabilities: streamingCapabilities
            ),
            config: config,
            listener: listener,
            security: security,
            sessionGrammar: sessionGrammar
        )
    }

    var id: ChannelId { surface.id }
    var meta: ChannelSurfaceMeta { surface.meta }
    var capabilities: ChannelCapabilities { surface.capabilities }
    var outbound: any ChannelOutboundAdapting { surface.outbound }
    var threading: (any ChannelThreadingAdapting)? { surface.threading }
    var heartbeat: (any ChannelHeartbeatAdapting)? { surface.heartbeat }
    var approvalCapability: (any ChannelApprovalCapabilityAdapting)? { surface.approvalCapability }
    var messageToolDescriptor: (any ChannelMessageToolDescribing)? { surface.messageToolDescriptor }
    var streamingCapabilities: StreamingSurfaceCapabilities { surface.streamingCapabilities }
}
