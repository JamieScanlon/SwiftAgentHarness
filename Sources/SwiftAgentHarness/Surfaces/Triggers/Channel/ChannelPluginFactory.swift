import Foundation
import Logging

struct ChannelBuiltListenerBundle: Sendable {
    var plugin: ChannelPlugin
    var listener: any ChannelSupervisedListening
    var parseRawEvent: @Sendable (ChannelTransportRawEvent) -> ChannelMessageEvent?
}

enum ChannelPluginFactory {
    static func build(
        channel: ChannelId,
        config: ChannelListenerConfig,
        logger: Logger
    ) throws -> ChannelBuiltListenerBundle {
        switch config.transport {
        case .mock:
            let listener = MockChannelListener(id: channel, config: config, logger: logger)
            let plugin = makeMockPlugin(channel: channel, config: config, listener: listener, logger: logger)
            return ChannelBuiltListenerBundle(
                plugin: plugin,
                listener: listener,
                parseRawEvent: MockChannelEventParser.parseRawEvent
            )
        case .slack, .telegram, .discord, .email:
            throw ChannelTransportBuildError.notImplemented(config.transport)
        }
    }

    private static func makeMockPlugin(
        channel: ChannelId,
        config: ChannelListenerConfig,
        listener: MockChannelListener,
        logger: Logger
    ) -> ChannelPlugin {
        _ = logger
        let chunkLimit = config.streaming.textChunkLimit
        let streamingPreset = config.streaming.preset
        let streamingCapabilities: StreamingSurfaceCapabilities = switch streamingPreset {
        case .social: .socialChannel
        case .operator: .operatorChannel
        case .finalOnly: .finalOnly
        }
        var adjusted = streamingCapabilities
        adjusted.chunker.textChunkLimit = chunkLimit
        adjusted.chunker.maxChars = min(adjusted.chunker.maxChars, chunkLimit)
        let surface = ChannelSurfacePluginFactory.build(
            channel: channel,
            meta: ChannelSurfaceMeta(platformIdentity: config.platformIdentity, transportKind: config.transport),
            listener: listener,
            heartbeat: listener,
            streamingCapabilities: adjusted,
            capabilities: .mock,
            chunkLimit: chunkLimit
        )
        return ChannelPlugin(
            surface: surface,
            config: config,
            listener: listener,
            security: DefaultChannelSecurityAdapter(config: config),
            sessionGrammar: ChannelSessionGrammar(config: config)
        )
    }
}

extension MockChannelListener: ChannelHeartbeatAdapting {}
