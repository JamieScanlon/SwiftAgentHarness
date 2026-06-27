import Foundation
import Logging

protocol ChannelPluginLooking: Sendable {
    func plugin(for channel: ChannelId) async -> ChannelPlugin?
}

protocol ChannelListenerLooking: ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelListener)?
}

extension ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelListener)? {
        await plugin(for: channel)?.listener
    }
}

public actor ChannelListenerRegistry: ChannelListenerLooking {
    private let dataDirectory: URL
    private let ingress: ChannelIngressAdapter
    private let logger: Logger
    private let enabled: Bool
    private var services: [ChannelId: ChannelListenerService] = [:]
    private var plugins: [ChannelId: ChannelPlugin] = [:]

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
        let built = Self.buildServicesAndPlugins(
            dataDirectory: dataDirectory,
            ingress: ingress,
            logger: logger,
            channelsFile: channelsFile
        )
        self.services = built.services
        self.plugins = built.plugins
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

    public func start() async {
        guard enabled else { return }
        registerMessageToolSchemas()
        await registerMessageOutputDeliverers()
        for service in services.values {
            await service.start()
        }
    }

    func plugin(for channel: ChannelId) async -> ChannelPlugin? {
        plugins[channel]
    }

    private func registerMessageToolSchemas() {
        let schemas = plugins.values.flatMap { plugin in
            plugin.messageToolDescriptor?.describeMessageTool() ?? []
        }
        MessageToolSchemaRegistry.register(actionSchemas: schemas)
    }

    private func registerMessageOutputDeliverers() async {
        let deliverer = ChannelMessageOutputDeliverer { [plugins] channel in
            plugins[channel]
        }
        for (channel, _) in plugins {
            await MessageOutputDeliveryRegistry.shared.register(
                surfaceID: channel.rawValue,
                deliverer: deliverer
            )
        }
    }

    public func stop() async {
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

    private static func buildServicesAndPlugins(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        logger: Logger,
        channelsFile: ChannelsFile
    ) -> (services: [ChannelId: ChannelListenerService], plugins: [ChannelId: ChannelPlugin]) {
        var result: [ChannelId: ChannelListenerService] = [:]
        var pluginMap: [ChannelId: ChannelPlugin] = [:]
        let mediaRoot = dataDirectory.deletingLastPathComponent().appendingPathComponent("channel-media", isDirectory: true)
        for channel in [ChannelId.slack, .telegram, .discord, .email] {
            guard let config = channelsFile.config(for: channel), config.enabled else { continue }
            if config.dmScope == .main {
                logger.warning("channel_dm_scope_main channel=\(channel.rawValue) risks cross-peer DM leakage on multi-user channels")
            }
            guard config.transport == .mock else { continue }
            let listener = MockChannelListener(id: channel, config: config, logger: logger)
            let plugin = ChannelPluginFactory.makeMockPlugin(
                channel: channel,
                config: config,
                listener: listener,
                logger: logger
            )
            pluginMap[channel] = plugin
            result[channel] = ChannelListenerService(
                channel: channel,
                listener: listener,
                dataDirectory: dataDirectory,
                mediaRoot: mediaRoot,
                ingress: ingress,
                logger: logger
            )
        }
        return (result, pluginMap)
    }
}
