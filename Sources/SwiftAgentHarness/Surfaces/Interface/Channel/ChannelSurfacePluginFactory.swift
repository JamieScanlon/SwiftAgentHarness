import Foundation

public enum ChannelSurfacePluginFactory {
    public static func build(
        channel: ChannelId,
        meta: ChannelSurfaceMeta,
        listener: any ChannelOutboundListening,
        heartbeat: (any ChannelHeartbeatAdapting)?,
        streamingCapabilities: StreamingSurfaceCapabilities,
        capabilities: ChannelCapabilities = .mock,
        chunkLimit: Int = 4000,
        presentationCapabilities: ChannelPresentationCapabilities = .mockRich,
        threading: (any ChannelThreadingAdapting)? = DefaultChannelThreadingAdapter(),
        messageToolDescriptor: (any ChannelMessageToolDescribing)? = nil
    ) -> ChannelSurfacePlugin {
        let outbound = DefaultChannelOutboundAdapter(
            listener: listener,
            chunkLimit: chunkLimit,
            presentationCapabilities: presentationCapabilities
        )
        return ChannelSurfacePlugin(
            id: channel,
            meta: meta,
            capabilities: capabilities,
            outbound: outbound,
            threading: threading,
            heartbeat: heartbeat,
            approvalCapability: ChannelApprovalCapabilityAdapter(outbound: outbound),
            messageToolDescriptor: messageToolDescriptor ?? MockChannelMessageToolDescriptor(channel: channel),
            streamingCapabilities: streamingCapabilities
        )
    }
}
