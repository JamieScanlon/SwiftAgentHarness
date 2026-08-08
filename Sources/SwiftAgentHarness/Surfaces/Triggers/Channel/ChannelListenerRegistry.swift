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

/// One channel's lifecycle state, safe to show a caller.
///
/// Deliberately narrower than `ChannelRuntimeStatusSnapshot`: no `platformIdentity`, no
/// `primaryUser`, and the fatal error is reduced to its **code**. A fatal message is
/// `String(describing:)` of a transport error, which routinely carries the URL and occasionally the
/// token that was rejected — not something to hand to a caller that only asked whether Slack is up.
///
/// `running` and `fatalCode` are reported independently on purpose. `ChannelSupervisedListening` has
/// no `clearFatal`, so a listener that went fatal and was later restarted still carries the old
/// error; `running: true, fatalCode: "connect_failed"` reads as "recovered after that failure",
/// which is strictly more information than suppressing either field would give.
struct ChannelStatusSummary: Sendable, Equatable {
    var channel: ChannelId
    var transport: ChannelTransportKind
    /// What `channels.json` permits. Authoritative; no runtime surface changes it.
    var configEnabled: Bool
    /// Whether a runtime overlay is currently holding this channel off.
    var runtimeDisabled: Bool
    /// The overlay could not be read. `runtimeDisabled` is then a guess, not a fact, and this flag
    /// is the only thing that says so — without it the summary cannot express "I don't know".
    var overlayUnreadable: Bool
    /// Whether a supervisor is actually attached right now.
    var running: Bool
    /// Whether a listener service exists for this channel at all.
    ///
    /// False means config named the channel but nothing was built for it — either it was disabled at
    /// process start (services are built once, in `init`) or its transport is still a stub. This is
    /// the field that answers "my channel is in the config, why is nothing happening"; without it,
    /// `running: false` conflates "paused" with "there is no such listener".
    var serviceBuilt: Bool
    var state: ChannelListenerState
    var fatalCode: String?
}

/// What one `reload` call did. `true`/`false` could not distinguish "restarted" from "deliberately
/// left down", which are the two outcomes a caller most needs to tell apart.
enum ChannelReloadOutcome: String, Sendable, Equatable {
    case restarted
    /// Stopped and left stopped: config or the overlay says this channel should not be running.
    case heldOff
    case noService
    case registryDisabled
}

/// What a reconcile actually did.
struct ChannelReconcileReport: Sendable, Equatable {
    var started: [ChannelId] = []
    var stopped: [ChannelId] = []
    var unchanged: [ChannelId] = []
    /// Channels whose `channels.json` entry changed in a way this reconcile cannot apply.
    ///
    /// Reconcile moves listeners between started and stopped; it does not rebuild a service, so a
    /// changed transport, credential, or debounce setting needs a process restart. Reported rather
    /// than silently ignored — "I reloaded and nothing happened" is the confusing outcome.
    var requiresRestart: [ChannelId] = []
    /// Channels dropped from `channels.json` since boot. Stopped by this reconcile; the built
    /// service stays in memory until restart.
    var removedFromConfig: [ChannelId] = []
    var diagnostics: [ChannelConfigDiagnostic] = []
}

public actor ChannelListenerRegistry: ChannelListenerLooking {
    private let dataDirectory: URL
    private let ingress: ChannelIngressAdapter
    private let logger: Logger
    private let enabled: Bool
    private var services: [ChannelId: ChannelListenerService] = [:]
    private var plugins: [ChannelId: ChannelPlugin] = [:]
    /// The config each service was built from. Refreshed from disk by `refreshedConfig()`, so
    /// lifecycle decisions are never made against a boot-time snapshot the operator has since edited.
    private var configs: [ChannelId: ChannelListenerConfig] = [:]
    private let configURL: URL
    /// Persisted runtime lifecycle overlay. Optional so existing fixtures construct unchanged.
    private let runtimeState: ChannelRuntimeStateStore?
    /// Last overlay that decoded cleanly.
    ///
    /// A read failure falls back to *this*, never to "no overlay". Falling back to permissive would
    /// mean anyone who can corrupt one byte of the overlay file re-enables every channel the owner
    /// disabled — the exact reset the store's throw-on-corrupt exists to prevent, reintroduced one
    /// layer up. Corruption before the first successful read is genuinely undecidable (deleting the
    /// file is indistinguishable from never having disabled anything), so that case runs open and
    /// says so via `overlayUnreadable`.
    private var lastGoodOverlay: [String: ChannelRuntimeStateEntry] = [:]
    private var overlayEverRead = false
    private var overlayUnreadable = false
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
        channelsFile: ChannelsFile,
        configURL: URL? = nil,
        runtimeState: ChannelRuntimeStateStore? = nil
    ) {
        self.dataDirectory = dataDirectory
        self.ingress = ingress
        self.logger = logger
        self.enabled = enabled
        self.configURL = configURL ?? dataDirectory.appendingPathComponent("channels.json")
        self.runtimeState = runtimeState
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
        self.configs = built.configs
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
        configURL: URL?,
        runtimeState: ChannelRuntimeStateStore? = nil
    ) -> ChannelListenerRegistry {
        let url = configURL ?? dataDirectory.appendingPathComponent("channels.json")
        let result = ChannelConfigLoader.loadResult(from: url)
        Self.report(result.diagnostics, logger: logger)
        return ChannelListenerRegistry(
            dataDirectory: dataDirectory,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            channelRunStreaming: channelRunStreaming,
            logger: logger,
            enabled: enabled,
            channelsFile: result.file,
            configURL: url,
            runtimeState: runtimeState
        )
    }

    /// A malformed config used to be indistinguishable from an empty one — same empty `ChannelsFile`,
    /// no log line, every channel silently off. That is the shape of "my channel vanished".
    private static func report(_ diagnostics: [ChannelConfigDiagnostic], logger: Logger) {
        for diagnostic in diagnostics {
            if diagnostic.isFailure {
                logger.error("\(diagnostic.message)")
            } else {
                logger.debug("\(diagnostic.message)")
            }
        }
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
        // Outbound capability follows the channel's *live* state. Both registries are keyed by
        // `channel.rawValue`, so a held-off channel is simply never armed, and one paused later is
        // withdrawn by `reconcile()`. Before they were keyed, everything configured was registered
        // at boot and never removed — so disabling a channel stopped it listening while leaving the
        // agent able to send there.
        let overlay = currentOverlay()
        for (channel, service) in services {
            guard !overlay.disabled(channel) else {
                logger.info("channel_listener_held_off channel=\(channel.rawValue) reason=runtime-disabled")
                await withdrawOutbound(channel)
                continue
            }
            await service.start()
            await syncOutbound(channel, service: service)
        }
    }

    // MARK: - Config and overlay reads

    /// Re-read `channels.json` and refresh `configs` for channels that still have a service.
    ///
    /// Every lifecycle decision goes through here rather than through the boot-time snapshot: an
    /// operator who edits config and then triggers a reload must not be overruled by what the file
    /// said at process start.
    @discardableResult
    private func refreshedConfig() -> ChannelConfigLoadResult {
        let result = ChannelConfigLoader.loadResult(from: configURL)
        Self.report(result.diagnostics, logger: logger)
        guard result.decodedCleanly else { return result }
        for channel in services.keys {
            if let current = result.file.config(for: channel) {
                configs[channel] = current
            } else {
                // Dropped from config entirely. Keep the last known entry for the transport label in
                // status, but force `enabled` false so every desired-state computation stops it.
                configs[channel]?.enabled = false
            }
        }
        return result
    }

    /// One read of the overlay, reused across a whole operation.
    ///
    /// Read once per call, not once per channel: `runtimeEnabled` used to decode the entire file for
    /// every channel it was asked about, so one `channel` tool call was N synchronous file reads
    /// blocking this actor's executor.
    struct OverlaySnapshot: Sendable {
        var entries: [String: ChannelRuntimeStateEntry]
        var unreadable: Bool

        func disabled(_ channel: ChannelId) -> Bool {
            entries[channel.rawValue]?.disabled == true
        }
    }

    /// Load the overlay, maintaining the last-good fallback.
    ///
    /// On a read error this falls back to the last overlay that decoded cleanly — not to "permitted".
    /// See ``lastGoodOverlay``.
    private func currentOverlay() -> OverlaySnapshot {
        guard let runtimeState else { return OverlaySnapshot(entries: [:], unreadable: false) }
        do {
            let channels = try runtimeState.load()
            lastGoodOverlay = channels
            overlayEverRead = true
            overlayUnreadable = false
            return OverlaySnapshot(entries: channels, unreadable: false)
        } catch {
            overlayUnreadable = true
            logger.error("channel_runtime_state_unreadable error=\(String(describing: error))")
            guard overlayEverRead else { return OverlaySnapshot(entries: [:], unreadable: true) }
            return OverlaySnapshot(entries: lastGoodOverlay, unreadable: true)
        }
    }

    /// `configEnabled ∧ ¬runtimeDisabled ∧ registryEnabled` — the one place the attenuation rule is
    /// written down. Every start/stop decision calls this rather than restating it.
    private func desiredState(for channel: ChannelId, overlay: OverlaySnapshot) -> Bool {
        guard enabled else { return false }
        guard configs[channel]?.enabled == true else { return false }
        return !overlay.disabled(channel)
    }

    func plugin(for channel: ChannelId) async -> ChannelPlugin? {
        plugins[channel]
    }

    /// Arm a channel's *outbound* surface: what the agent may send, and where it lands.
    ///
    /// Separate from `start()` because outbound capability now tracks the channel's live state
    /// rather than the boot-time config — see ``withdrawOutbound(_:)``.
    private func armOutbound(_ channel: ChannelId) async {
        guard let plugin = plugins[channel] else { return }
        MessageToolSchemaRegistry.register(
            surfaceID: channel.rawValue,
            actionSchemas: plugin.surface.messageToolDescriptor?.describeMessageTool() ?? []
        )
        await MessageOutputDeliveryRegistry.shared.register(
            surfaceID: channel.rawValue,
            // `[weak self]`, not a by-value snapshot of `plugins`. A snapshot cannot see a channel
            // built after it was armed — the phase-4b case — and a *strong* capture would pin this
            // registry alive for the process lifetime, because `MessageOutputDeliveryRegistry.shared`
            // is a global that holds its deliverers. Once the registry is gone the lookup returns
            // nil and delivery no-ops, which is the right end state for a torn-down surface.
            deliverer: ChannelMessageOutputDeliverer { [weak self, logger] channel in
                guard let self else {
                    // Every layer below returns silently on a nil surface, so without this an
                    // agent's message to this channel would vanish with no record anywhere.
                    logger.warning(
                        "channel_outbound_registry_released channel=\(channel.rawValue) — delivery dropped"
                    )
                    return nil
                }
                return await self.plugins[channel]?.surface
            }
        )
    }

    /// Withdraw it again.
    ///
    /// Pausing a channel used to stop it *listening* while leaving the agent able to send there:
    /// the deliverer stayed in the registry keyed by `channel.rawValue`, so a `message` tool call
    /// still resolved and reached a stopped transport, and the tool schema still advertised that
    /// channel's media params. Both registries are keyed by the same string, so both come down here.
    /// Point outbound at reality: armed exactly when the listener is actually running.
    ///
    /// Arming *before* `start()` and never unwinding left a channel advertising itself after a
    /// failed start — and `reconcile()` could then never withdraw it, because its `desired ==
    /// running` short-circuit sees `false == false` and reports "unchanged". Deciding from
    /// `isRunning` after the fact makes both cases fall out.
    private func syncOutbound(_ channel: ChannelId, service: ChannelListenerService) async {
        if await service.isRunning {
            await armOutbound(channel)
        } else {
            await withdrawOutbound(channel)
        }
    }

    private func withdrawOutbound(_ channel: ChannelId) async {
        MessageToolSchemaRegistry.unregister(surfaceID: channel.rawValue)
        await MessageOutputDeliveryRegistry.shared.unregister(surfaceID: channel.rawValue)
    }

    /// Stops listening *and* withdraws outbound, so process shutdown does not leave the global
    /// registries holding every plugin this registry built.
    public func stop() async {
        for (channel, service) in services {
            await service.stop()
            await withdrawOutbound(channel)
        }
    }

    // MARK: - Lifecycle control

    /// Stop then start one channel — the "transport wedged without going fatal" escape hatch.
    ///
    /// There is deliberately no `setEnabled(channel:_:)` counterpart. A method that started a
    /// listener from a caller's boolean would be a second, unaudited way to override the overlay the
    /// owner just wrote; enabling and disabling go through
    /// `TriggerRegistrationService.setChannelEnabled` (authority, persistence, audit) and land here
    /// via ``reconcile()``.
    @discardableResult
    func reload(channel: ChannelId) async -> ChannelReloadOutcome {
        guard enabled else { return .registryDisabled }
        guard let service = services[channel] else { return .noService }
        refreshedConfig()
        await service.stop()
        guard desiredState(for: channel, overlay: currentOverlay()) else {
            await withdrawOutbound(channel)
            return .heldOff
        }
        await service.start()
        await syncOutbound(channel, service: service)
        return .restarted
    }

    /// Bring every listener into line with `channels.json` ∧ the runtime overlay.
    ///
    /// This is the method an owner client calls after writing the overlay. It re-reads config so
    /// drift is *reported*, but it does not rebuild services — a changed transport or credential
    /// needs a process restart, and saying so beats appearing to have applied it.
    @discardableResult
    func reconcile() async -> ChannelReconcileReport {
        var report = ChannelReconcileReport()
        let built = configs
        let result = refreshedConfig()
        let overlay = currentOverlay()
        report.diagnostics = result.diagnostics

        for (channel, service) in services.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // Drift detection is gated on the file having *decoded*, not on `isAuthoritative`: an
            // unknown-channel typo elsewhere in the file must not suppress reporting for the
            // channels that parsed perfectly well.
            if result.decodedCleanly {
                let currentConfig = result.file.config(for: channel)
                if currentConfig == nil {
                    report.removedFromConfig.append(channel)
                } else if var comparable = built[channel], let currentConfig {
                    // Compare everything *except* the lifecycle flag, which reconcile applies itself.
                    comparable.enabled = currentConfig.enabled
                    if comparable != currentConfig {
                        report.requiresRestart.append(channel)
                    }
                }
            }
            let desired = desiredState(for: channel, overlay: overlay)
            let running = await service.isRunning
            if desired == running {
                // Still reconcile outbound. A channel whose start failed reads `running == false`
                // while the overlay says `desired == false` too, so this branch is taken — and
                // before, that left it armed with nothing listening behind it.
                await syncOutbound(channel, service: service)
                report.unchanged.append(channel)
                continue
            }
            if desired {
                await service.start()
                report.started.append(channel)
            } else {
                await service.stop()
                report.stopped.append(channel)
            }
            await syncOutbound(channel, service: service)
        }

        // A channel the operator has since switched on has no service to start: services are built
        // once, in `init`, over the channels that were enabled and whose transport is implemented.
        // Without this it would reconcile to "unchanged" and report nothing at all.
        if result.decodedCleanly {
            for channel in ChannelId.allCases where services[channel] == nil {
                guard result.file.config(for: channel)?.enabled == true else { continue }
                report.requiresRestart.append(channel)
            }
        }
        return report
    }

    /// Redacted lifecycle view of every configured channel.
    ///
    /// Not owner-filtered, because every channel here is one the operator wrote into this
    /// deployment's `channels.json`; there is no cross-tenant set to leak between. Owner filtering
    /// belongs on the *overlay* read, which carries per-actor attribution — see
    /// `TriggerRegistrationService.channelRuntimeState(authority:)`.
    /// Iterates **config**, not `services`, and that is the whole point.
    ///
    /// `services` holds only channels that were enabled at process start *and* have an implemented
    /// transport. Reporting from it meant a channel with `enabled: false`, or one whose transport is
    /// still a stub, was absent from the listing entirely and answered "not configured" on lookup —
    /// so the tool told a user their Slack was unconfigured when it was configured and switched off.
    /// That is precisely the question this exists to answer.
    func statuses() async -> [ChannelStatusSummary] {
        let result = refreshedConfig()
        let overlay = currentOverlay()
        var summaries: [ChannelStatusSummary] = []
        for channel in ChannelId.allCases {
            // Fall back to the built snapshot when the file did not decode, rather than reporting
            // every channel as absent because of one bad byte.
            let config = result.decodedCleanly ? result.file.config(for: channel) : configs[channel]
            // Genuinely not in `channels.json`. The only case that is truly "not configured".
            guard let config else { continue }
            let service = services[channel]
            let listener = await service?.listenerInstance()
            summaries.append(
                ChannelStatusSummary(
                    channel: channel,
                    transport: config.transport,
                    configEnabled: config.enabled,
                    runtimeDisabled: overlay.disabled(channel),
                    overlayUnreadable: overlay.unreadable,
                    running: await service?.isRunning ?? false,
                    serviceBuilt: service != nil,
                    state: listener?.state ?? .disconnected,
                    fatalCode: listener?.fatalError?.code
                )
            )
        }
        return summaries
    }

    /// Channels that have a built service — i.e. present in config, enabled at build time, and whose
    /// transport is implemented. A channel named in config whose transport is a stub is absent here,
    /// which is what makes "why is my channel missing" answerable.
    func configuredChannels() -> [ChannelId] {
        services.keys.sorted { $0.rawValue < $1.rawValue }
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
    ) -> (
        services: [ChannelId: ChannelListenerService],
        plugins: [ChannelId: ChannelPlugin],
        configs: [ChannelId: ChannelListenerConfig]
    ) {
        var result: [ChannelId: ChannelListenerService] = [:]
        var pluginMap: [ChannelId: ChannelPlugin] = [:]
        var configMap: [ChannelId: ChannelListenerConfig] = [:]
        let mediaRoot = dataDirectory.deletingLastPathComponent().appendingPathComponent("channel-media", isDirectory: true)
        for channel in ChannelId.allCases {
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
            configMap[channel] = config
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
        return (result, pluginMap, configMap)
    }
}
