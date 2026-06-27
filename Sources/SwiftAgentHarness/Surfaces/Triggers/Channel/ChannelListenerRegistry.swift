import Foundation
import Logging

protocol ChannelPluginLooking: Sendable {
    func plugin(for channel: ChannelId) async -> ChannelPlugin?
}

protocol ChannelListenerLooking: ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelSupervisedListening)?
}

extension ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelSupervisedListening)? {
        await plugin(for: channel)?.listener as? any ChannelSupervisedListening
    }
}

public actor ChannelListenerRegistry: ChannelListenerLooking {
    private let dataDirectory: URL
    private let ingress: ChannelIngressAdapter
    private let logger: Logger
    private let enabled: Bool
    private var services: [ChannelId: ChannelListenerService] = [:]
    private var plugins: [ChannelId: ChannelPlugin] = [:]
    private let lifecycleCoordinator: ChannelSessionLifecycleCoordinator?
    private let channelRunStreaming: ChannelRunStreamingServiceHolder?

    init(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        dedupe: any TriggerDedupeChecking,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil,
        channelRunStreaming: ChannelRunStreamingServiceHolder? = nil,
        logger: Logger,
        enabled: Bool,
        channelsFile: ChannelsFile
    ) {
        self.dataDirectory = dataDirectory
        self.ingress = ingress
        self.logger = logger
        self.enabled = enabled
        self.lifecycleCoordinator = lifecycleCoordinator
        self.channelRunStreaming = channelRunStreaming
        let built = Self.buildServicesAndPlugins(
            dataDirectory: dataDirectory,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            logger: logger,
            channelsFile: channelsFile
        )
        self.services = built.services
        self.plugins = built.plugins
        if let lifecycleCoordinator {
            let services = built.services
            lifecycleCoordinator.setSessionDrainHandler { result in
                guard let channel = result.channel, !result.burstKeys.isEmpty else { return }
                await services[channel]?.cancelDebounce(burstKeys: result.burstKeys)
            }
        }
    }

    static func load(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        dedupe: any TriggerDedupeChecking,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil,
        channelRunStreaming: ChannelRunStreamingServiceHolder? = nil,
        logger: Logger,
        enabled: Bool,
        configURL: URL?
    ) -> ChannelListenerRegistry {
        let url = configURL ?? dataDirectory.appendingPathComponent("channels.json")
        let channelsFile = ChannelConfigLoader.load(from: url)
        return ChannelListenerRegistry(
            dataDirectory: dataDirectory,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            channelRunStreaming: channelRunStreaming,
            logger: logger,
            enabled: enabled,
            channelsFile: channelsFile
        )
    }

    func drainSessionLifecycle(conversationID: UUID) async {
        if let service = channelRunStreaming?.service() {
            await service.detach(conversationID: conversationID)
        } else {
            _ = await lifecycleCoordinator?.drainSession(conversationID: conversationID)
        }
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
            plugin.surface.messageToolDescriptor?.describeMessageTool() ?? []
        }
        MessageToolSchemaRegistry.register(actionSchemas: schemas)
    }

    private func registerMessageOutputDeliverers() async {
        let deliverer = ChannelMessageOutputDeliverer { [plugins] channel in
            plugins[channel]?.surface
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

    func listener(for channel: ChannelId) async -> (any ChannelSupervisedListening)? {
        guard let service = services[channel] else { return nil }
        return await service.listenerInstance()
    }

    private static func buildServicesAndPlugins(
        dataDirectory: URL,
        ingress: ChannelIngressAdapter,
        dedupe: any TriggerDedupeChecking,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator?,
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
            let bundle: ChannelBuiltListenerBundle
            do {
                bundle = try ChannelPluginFactory.build(channel: channel, config: config, logger: logger)
            } catch ChannelTransportBuildError.notImplemented(let transport) {
                logger.warning("channel_transport_not_implemented channel=\(channel.rawValue) transport=\(transport.rawValue)")
                continue
            } catch {
                logger.error("channel_transport_build_failed channel=\(channel.rawValue) error=\(String(describing: error))")
                continue
            }
            pluginMap[channel] = bundle.plugin
            result[channel] = ChannelListenerService(
                channel: channel,
                bundle: bundle,
                dataDirectory: dataDirectory,
                mediaRoot: mediaRoot,
                ingress: ingress,
                dedupe: dedupe,
                lifecycleCoordinator: lifecycleCoordinator,
                logger: logger
            )
        }
        return (result, pluginMap)
    }
}
