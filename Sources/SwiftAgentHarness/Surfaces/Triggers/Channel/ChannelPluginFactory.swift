import Foundation
import Logging

enum ChannelPluginFactory {
    static func makeMockPlugin(
        channel: ChannelId,
        config: ChannelListenerConfig,
        listener: MockChannelListener,
        logger: Logger
    ) -> ChannelPlugin {
        let chunkLimit = config.streaming.textChunkLimit
        let streamingPreset = config.streaming.preset
        let outbound = DefaultChannelOutboundAdapter(
            listener: listener,
            chunkLimit: chunkLimit,
            presentationCapabilities: .mockRich
        )
        let streamingCapabilities: StreamingSurfaceCapabilities = switch streamingPreset {
        case .social: .socialChannel
        case .operator: .operatorChannel
        case .finalOnly: .finalOnly
        }
        var adjusted = streamingCapabilities
        adjusted.chunker.textChunkLimit = chunkLimit
        adjusted.chunker.maxChars = min(adjusted.chunker.maxChars, chunkLimit)
        return ChannelPlugin(
            id: channel,
            meta: ChannelPluginMeta(platformIdentity: config.platformIdentity, transportKind: config.transport),
            capabilities: .mock,
            config: config,
            listener: listener,
            outbound: outbound,
            threading: DefaultChannelThreadingAdapter(),
            sessionGrammar: ChannelSessionGrammar(),
            security: DefaultChannelSecurityAdapter(config: config),
            heartbeat: listener,
            approvalCapability: ChannelApprovalCapabilityAdapter(outbound: outbound),
            messageToolDescriptor: MockChannelMessageToolDescriptor(channel: channel),
            streamingCapabilities: adjusted
        )
    }
}

struct MockChannelMessageToolDescriptor: ChannelMessageToolDescribing {
    let channel: ChannelId

    func describeMessageTool() -> [MessageToolActionSchema] {
        [
            MessageToolActionSchema(
                action: "post",
                mediaParams: [
                    MessageToolMediaParamDescriptor(
                        name: "coverImageURL",
                        type: "string",
                        description: "Optional cover image for \(channel.rawValue) cards."
                    ),
                ]
            ),
        ]
    }
}

extension MockChannelListener: ChannelHeartbeatAdapting {}
