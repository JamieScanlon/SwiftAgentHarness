import Foundation
import Logging

protocol ChannelListenerLooking: Sendable {
    func listener(for channel: ChannelId) async -> (any ChannelListener)?
}

actor ChannelListenerRegistry: ChannelListenerLooking {
    private let dataDirectory: URL
    private let ingress: ChannelIngressAdapter
    private let logger: Logger
    private let enabled: Bool
    private var services: [ChannelId: ChannelListenerService] = [:]

    init(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        logger: Logger,
        enabled: Bool,
        channelsFile: ChannelsFile
    ) {
        self.dataDirectory = dataDirectory
        self.ingress = ingress
        self.logger = logger
        self.enabled = enabled
        self.services = Self.buildServices(
            dataDirectory: dataDirectory,
            ingress: ingress,
            logger: logger,
            channelsFile: channelsFile
        )
    }

    static func load(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        logger: Logger,
        enabled: Bool,
        configURL: URL?
    ) -> ChannelListenerRegistry {
        let url = configURL ?? dataDirectory.appendingPathComponent("channels.json")
        let channelsFile = ChannelConfigLoader.load(from: url)
        return ChannelListenerRegistry(
            dataDirectory: dataDirectory,
            ingress: ingress,
            logger: logger,
            enabled: enabled,
            channelsFile: channelsFile
        )
    }

    func start() async {
        guard enabled else { return }
        for service in services.values {
            await service.start()
        }
    }

    func stop() async {
        for service in services.values {
            await service.stop()
        }
    }

    func service(for channel: ChannelId) -> ChannelListenerService? {
        services[channel]
    }

    func listener(for channel: ChannelId) async -> (any ChannelListener)? {
        guard let service = services[channel] else { return nil }
        return await service.listenerInstance()
    }

    private static func buildServices(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        logger: Logger,
        channelsFile: ChannelsFile
    ) -> [ChannelId: ChannelListenerService] {
        var result: [ChannelId: ChannelListenerService] = [:]
        let mediaRoot = dataDirectory.deletingLastPathComponent().appendingPathComponent("channel-media", isDirectory: true)
        for channel in [ChannelId.slack, .telegram, .discord, .email] {
            guard let config = channelsFile.config(for: channel), config.enabled else { continue }
            if config.dmScope == .main {
                logger.warning("channel_dm_scope_main channel=\(channel.rawValue) risks cross-peer DM leakage on multi-user channels")
            }
            guard config.transport == .mock else { continue }
            let listener = MockChannelListener(id: channel, config: config, logger: logger)
            result[channel] = ChannelListenerService(
                channel: channel,
                listener: listener,
                dataDirectory: dataDirectory,
                mediaRoot: mediaRoot,
                ingress: ingress,
                logger: logger
            )
        }
        return result
    }
}
