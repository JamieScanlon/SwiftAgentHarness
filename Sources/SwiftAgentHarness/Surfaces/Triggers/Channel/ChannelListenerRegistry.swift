import Foundation
import Logging
import Synchronization

protocol ChannelPluginLooking: Sendable {
    func plugin(for channel: ChannelId) async -> ChannelPlugin?
    /// The plugin, but only while the agent may actually send to that channel *right now*.
    ///
    /// `plugin(for:)` answers "does this channel exist"; this answers "is its listener running".
    /// The distinction matters to any caller that resolves once and holds the result: a paused or
    /// torn-down channel keeps its plugin object, so a stored `plugin.outbound` goes on delivering
    /// long after the registry has withdrawn the channel from the outbound registries.
    func outboundPlugin(for channel: ChannelId) async -> ChannelPlugin?
}

protocol ChannelListenerLooking: ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelSupervisedListening)?
}

extension ChannelPluginLooking {
    func listener(for channel: ChannelId) async -> (any ChannelSupervisedListening)? {
        await plugin(for: channel)?.listener as? any ChannelSupervisedListening
    }

    /// Conformers with no lifecycle of their own — test stubs, direct plugin holders — cannot
    /// distinguish the two, and for them "exists" is the honest answer.
    func outboundPlugin(for channel: ChannelId) async -> ChannelPlugin? {
        await plugin(for: channel)
    }
}

/// The live services map, held where a closure that cannot capture the actor can still read it.
///
/// `ChannelListenerRegistry` is an actor, so `self` cannot escape its nonisolated `init` — which is
/// why the session-drain handler installed there closed over a **by-value snapshot** of the boot
/// services. That was invisible while services were built once and never changed; the moment
/// `reconcile()` can build one, a snapshot is a handler that silently cannot see it. Holding the map
/// here means the actor and the handler read the same storage, with no second copy to drift.
///
/// `Mutex`, not `NSLock`: this is reached from `async` context, which is the axis this codebase
/// picks its locking idiom on — the same call as `ChannelLifecycleApplierHolder`.
final class ChannelServiceBox: Sendable {
    private let storage: Mutex<[ChannelId: ChannelListenerService]>

    init(_ services: [ChannelId: ChannelListenerService]) {
        storage = Mutex(services)
    }

    func snapshot() -> [ChannelId: ChannelListenerService] {
        storage.withLock { $0 }
    }

    func replace(_ services: [ChannelId: ChannelListenerService]) {
        storage.withLock { $0 = services }
    }

    func service(_ channel: ChannelId) -> ChannelListenerService? {
        storage.withLock { $0[channel] }
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
    /// False means config named the channel but nothing was built for it. A `reconcile()` now builds
    /// any channel `channels.json` enables, so the remaining causes are: the transport is still a
    /// stub, its build failed, or channel listeners are switched off process-wide. This is the field
    /// that answers "my channel is in the config, why is nothing happening"; without it,
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
    /// Drift only. Reconcile *builds* a missing service, but it does not rebuild a live one: a
    /// changed transport, credential, or debounce setting still needs a process restart, because
    /// tearing a working listener down to pick up an edit would reconnect it as a side effect of an
    /// unrelated pause on some other channel, and drop its in-flight debounce buffers with it.
    /// Reported rather than silently ignored — "I reloaded and nothing happened" is the confusing
    /// outcome.
    var requiresRestart: [ChannelId] = []
    /// Channels absent from `channels.json` on this read. Always stopped by this reconcile; also
    /// withdrawn from the outbound registries and dropped from this registry's maps *when the file
    /// exists and simply omits them*. A file that is missing entirely stops them without tearing
    /// them down — see `performReconcile`, which explains why a transient read must not destroy.
    var removedFromConfig: [ChannelId] = []
    /// Channels this reconcile built a service for, because config enables them and none existed.
    ///
    /// One that was also started appears in ``started`` as well; the two answer different questions
    /// — "does a listener exist now" versus "is it running".
    var built: [ChannelId] = []
    /// Config enables these and no service exists, and one could not be built — an unimplemented
    /// transport, or a build error. Deliberately not folded into ``requiresRestart``: a restart fixes
    /// neither, and telling an operator to restart is worse than telling them nothing.
    var buildFailed: [ChannelId] = []
    var diagnostics: [ChannelConfigDiagnostic] = []
}

public actor ChannelListenerRegistry: ChannelListenerLooking {
    private let dataDirectory: URL
    private let ingress: ChannelIngressAdapter
    private let logger: Logger
    private let enabled: Bool
    private let dedupe: any TriggerDedupeChecking
    /// Where channel media lands. Held rather than recomputed so boot and the runtime build pass
    /// cannot derive two different roots.
    private let mediaRoot: URL
    private let serviceBox: ChannelServiceBox
    /// The actor-facing view of ``serviceBox``. Computed, not stored, so exactly one copy of this
    /// map exists in the process — a stored mirror would drift from the box the session-drain
    /// handler reads, which is the bug this replaced.
    private var services: [ChannelId: ChannelListenerService] {
        get { serviceBox.snapshot() }
        set { serviceBox.replace(newValue) }
    }
    private var plugins: [ChannelId: ChannelPlugin] = [:]
    /// The *current* config for each known channel. Refreshed from disk by `refreshedConfig()`, so
    /// lifecycle decisions are never made against a boot-time snapshot the operator has since edited.
    private var configs: [ChannelId: ChannelListenerConfig] = [:]
    /// Configs that already failed to build, so a reconcile neither retries nor re-logs a transport
    /// that cannot be built.
    ///
    /// Every owner pause or resume drives a reconcile, so without this a deployment with an
    /// unimplemented transport configured and enabled re-entered `ChannelPluginFactory.build` and
    /// emitted a `channel_transport_not_implemented` warning on every admin action, forever. Keyed by
    /// the config rather than the channel, so an operator edit clears it with no invalidation logic.
    private var unbuildableConfigs: [ChannelId: ChannelListenerConfig] = [:]
    /// The config each live service was actually built from. Written only when a service is built,
    /// never by a config read.
    ///
    /// Drift detection used to compare the freshly-read file against `configs` — which
    /// `refreshedConfig()` had just overwritten with that same file, and which `statuses()` also
    /// refreshes. So a credential change was reported by whichever call happened to read it first
    /// and by nothing afterwards: a read-only `channel` tool call erased the baseline, and every
    /// later reconcile found no difference while the listener kept running the old credential.
    private var builtConfigs: [ChannelId: ChannelListenerConfig] = [:]
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
    /// Serializes ``reconcile()`` against itself. See that method.
    private var reconcileRunning = false
    private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []

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
        self.dedupe = dedupe
        self.logger = logger
        self.enabled = enabled
        self.configURL = configURL ?? dataDirectory.appendingPathComponent("channels.json")
        self.runtimeState = runtimeState
        self.lifecycleCoordinator = lifecycleCoordinator
        self.channelRunStreaming = channelRunStreaming
        let mediaRoot = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("channel-media", isDirectory: true)
        self.mediaRoot = mediaRoot
        let built = Self.buildServicesAndPlugins(
            dataDirectory: dataDirectory,
            mediaRoot: mediaRoot,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            logger: logger,
            channelsFile: channelsFile
        )
        let serviceBox = ChannelServiceBox(built.services)
        self.serviceBox = serviceBox
        self.plugins = built.plugins
        self.configs = built.configs
        self.builtConfigs = built.configs
        if let lifecycleCoordinator {
            // Captures the *box*, never `self` — an actor's `self` cannot escape its nonisolated
            // `init`. This used to capture a by-value snapshot of the boot services, same shape and
            // same constraint, which could never see a channel built later.
            lifecycleCoordinator.setSessionDrainHandler { result in
                guard let channel = result.channel, !result.burstKeys.isEmpty else { return }
                await serviceBox.service(channel)?.cancelDebounce(burstKeys: result.burstKeys)
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
            // The loop iterates a snapshot and suspends inside; a concurrent teardown may have
            // detached this service since it was taken.
            guard isCurrent(service, for: channel) else { continue }
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
        // Every known channel, not just the ones with a service. `desiredState` reads `configs`, and
        // the runtime build pass has to be able to ask it about a channel that has no service *yet*;
        // iterating `services.keys` meant such a channel never got a `configs` entry at all.
        for channel in ChannelId.allCases {
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

    /// The plugin for `channel` while its listener is actually running.
    ///
    /// Derived from `isRunning` rather than from config or the overlay, for the same reason
    /// ``syncOutbound(_:service:)`` is: a channel whose start failed is not one the agent may send
    /// to, however permitted it looks on paper.
    func outboundPlugin(for channel: ChannelId) async -> ChannelPlugin? {
        guard let plugin = plugins[channel], let service = services[channel] else { return nil }
        guard await service.isRunning else { return nil }
        return plugin
    }

    /// Whether `service` is still this registry's service for `channel`.
    ///
    /// `start()`, `reload()` and `performReconcile()` each capture a `(channel, service)` pair and
    /// then suspend, and `removeService` can detach that service in between. Acting on a detached
    /// service starts a listener nothing can subsequently stop: it holds the instance lock, is absent
    /// from `services`, and is therefore invisible to `configuredChannels()`, `statuses()` and
    /// `stop()` — so it ingests until the process exits. Re-asserting identity after a suspension is
    /// half the fix; the other half is `ChannelListenerService.lifecycleEpoch`, which unwinds a start
    /// that a teardown's `stop()` superseded while it was still connecting.
    private func isCurrent(_ service: ChannelListenerService, for channel: ChannelId) -> Bool {
        services[channel] === service
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
        // A live run stream does not go through either registry: `ChannelRunStreamingService.attach`
        // resolves the plugin once and builds its sinks over `plugin.outbound` directly, so a turn
        // that was mid-answer kept pushing model output and typing indicators at a channel the owner
        // had just paused — the one case where "withdrawn" was not withdrawn. Terminating the stream
        // is the right shape rather than failing it per-message: the session is a live thing with a
        // teardown, not a lookup.
        if let streaming = channelRunStreaming?.service() {
            await streaming.detachAll(channel: channel)
        }
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
        guard isCurrent(service, for: channel) else { return .noService }
        await service.start()
        await syncOutbound(channel, service: service)
        return .restarted
    }

    /// Bring every listener into line with `channels.json` ∧ the runtime overlay.
    ///
    /// This is the method an owner client calls after writing the overlay. It re-reads config and
    /// acts on three kinds of difference: a channel config enables with no service is **built**; a
    /// channel dropped from config is **torn down**; a channel whose non-lifecycle settings changed
    /// is only *reported* in `requiresRestart`, because rebuilding a live listener would reconnect
    /// it as a side effect of an unrelated pause somewhere else.
    ///
    /// **Serialized against itself.** It decides from one config read and then acts across many
    /// suspensions, and an actor does not hold its executor across a suspension. Two owner actions
    /// arriving together — two `setChannelEnabled` calls, each driving `applyChannelState()` — used
    /// to interleave two passes, each acting on decisions the other had already invalidated: one
    /// could tear a channel down while the other was mid-`start()` on it, or skip building a channel
    /// the other was in the middle of removing, leaving it dark with nothing scheduled to retry.
    /// That is the same shape as the `ChannelListenerService.start()` reentrancy defect one layer
    /// down, and the same lesson — an actor is not mutual exclusion across `await`.
    ///
    /// Serialized rather than coalesced: a caller that has just persisted an overlay decision needs
    /// a pass that *read* it, or `appliedToRunningProcess: true` is a lie. Coalescing into an
    /// in-flight run would hand the second caller a pass that started before their write.
    @discardableResult
    func reconcile() async -> ChannelReconcileReport {
        // No cancellation check here, deliberately. An early return would have to invent a return
        // value, and an empty `ChannelReconcileReport` is indistinguishable from "ran and changed
        // nothing" — which is what `setChannelEnabled` would then persist in its audit row and what
        // the admin route would put on the wire as `appliedToRunningProcess: true`. A caller that is
        // going away is better served by a short wait than by a false account of what happened.
        //
        // The wait is bounded by the holder, but not tightly: a pass can make one `start()` per
        // `ChannelId` — each bounded by `ChannelListenerService.connectTimeout`, and only for a
        // transport that honours cancellation — plus, for every channel it withdraws, a stream drain
        // that awaits the drive task and is not bounded at all. Worth knowing before treating this
        // gate as cheap.
        while reconcileRunning {
            await withCheckedContinuation { continuation in
                reconcileWaiters.append(continuation)
            }
        }
        reconcileRunning = true
        // `defer`, not a straight-line release. Today `performReconcile()` cannot throw and has no
        // cancellation-throwing suspension, so a straight-line `reconcileRunning = false` would be
        // reachable — but it is one `try` away from wedging every channel lifecycle operation in the
        // process behind a flag nobody clears.
        defer {
            reconcileRunning = false
            // Wake everyone; the `while` above re-checks, so one proceeds and the rest re-queue.
            let waiters = reconcileWaiters
            reconcileWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return await performReconcile()
    }

    private func performReconcile() async -> ChannelReconcileReport {
        var report = ChannelReconcileReport()
        let result = refreshedConfig()
        let overlay = currentOverlay()
        report.diagnostics = result.diagnostics
        var channelsToRemove: [ChannelId] = []
        // An absent file is a clean decode of "no channels" — deleting `channels.json` is the most
        // emphatic way an operator has of switching everything off — but it is also what a
        // rename-based editor save, a deploy, or a mount blip looks like for a moment. Stopping on
        // that read is recoverable; *destroying* every service is not, because nothing schedules the
        // reconcile that would rebuild them. So a missing file stops channels, as it always did, and
        // only an existing file that omits a channel tears that channel down.
        let configFileMissing = result.diagnostics.contains { diagnostic in
            if case .fileMissing = diagnostic { return true }
            return false
        }

        for (channel, service) in services.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // The loop iterates a snapshot and suspends inside; a concurrent teardown may have
            // detached this service since it was taken.
            guard isCurrent(service, for: channel) else { continue }
            // Drift detection is gated on the file having *decoded*, not on `isAuthoritative`: an
            // unknown-channel typo elsewhere in the file must not suppress reporting for the
            // channels that parsed perfectly well.
            var scheduledForRemoval = false
            if result.decodedCleanly {
                if let currentConfig = result.file.config(for: channel) {
                    if var comparable = builtConfigs[channel] {
                        // Compare everything *except* the lifecycle flag, which reconcile applies
                        // itself.
                        comparable.enabled = currentConfig.enabled
                        if comparable != currentConfig {
                            report.requiresRestart.append(channel)
                        }
                    }
                } else {
                    report.removedFromConfig.append(channel)
                    if !configFileMissing {
                        channelsToRemove.append(channel)
                        scheduledForRemoval = true
                    }
                }
            }
            // `removeService` stops it, withdraws outbound and drops it. Falling through would run
            // the desired/running comparison below, which for a channel that was already stopped
            // takes the `desired == running` branch and reports `unchanged` — the one thing a
            // channel about to be destroyed definitively is not. It would also `stop()` it twice,
            // and the second stop writes a zeroed counter snapshot over the first.
            if scheduledForRemoval { continue }
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

        // Teardown after the loop, not inside it. The loop iterates a snapshot so mutating during it
        // would be safe, but keeping "decide" and "mutate" apart is what makes the loop readable.
        for channel in channelsToRemove {
            await removeService(channel)
        }

        // A channel the operator has since switched on. This used to be reportable only: services
        // were built once, in `init`, over the channels enabled at that moment with an implemented
        // transport, so the answer to "I enabled it, now what" was "restart the gateway".
        //
        // Deliberately NOT gated on the registry's `enabled` switch, even though nothing built here
        // will start while that switch is off. Boot builds a service for every config-enabled
        // channel regardless of it (`buildServicesAndPlugins` gates only on `config.enabled`), so
        // gating here would make `serviceBuilt` depend on whether a channel happened to be enabled
        // before or after process start — identical config, two different answers. One rule:
        // *building* follows config, *starting* follows `desiredState`, which is where the switch
        // lives.
        if result.decodedCleanly {
            for channel in ChannelId.allCases where services[channel] == nil {
                guard let config = result.file.config(for: channel), config.enabled else { continue }
                guard unbuildableConfigs[channel] != config else {
                    // Known unbuildable, still reported — an operator asking "why is my channel dark"
                    // needs the answer every time, not only the first.
                    report.buildFailed.append(channel)
                    continue
                }
                guard buildService(for: channel, config: config) else {
                    unbuildableConfigs[channel] = config
                    report.buildFailed.append(channel)
                    continue
                }
                report.built.append(channel)
                // Built but held off. The overlay attenuates here exactly as it does for a channel
                // built at boot, so status reads `serviceBuilt: true, running: false,
                // runtimeDisabled: true` and a later resume is a plain `start()`. Withdrawing
                // outbound is a no-op for a fresh build and clears any entry a previous incarnation
                // of this channel id left in the process-global registries.
                guard desiredState(for: channel, overlay: overlay), let service = services[channel] else {
                    await withdrawOutbound(channel)
                    continue
                }
                await service.start()
                await syncOutbound(channel, service: service)
                report.started.append(channel)
            }
        }
        // The report reaches no client today — `TriggersRuntimeWiring` discards it — so a drift that
        // is only *reported* is a drift nobody is told about. `makeService` already logs its build
        // failures; this was the remaining silent outcome.
        if !report.requiresRestart.isEmpty {
            let names = report.requiresRestart.map(\.rawValue).sorted().joined(separator: ",")
            logger.warning("channel_config_requires_restart channels=\(names)")
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
    /// `services` holds only channels a boot or a reconcile could build — enabled in config *and*
    /// with an implemented transport. Reporting from it meant a channel with `enabled: false`, or one
    /// whose transport is still a stub, was absent from the listing entirely and answered "not
    /// configured" on lookup —
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

    // MARK: - Runtime service construction

    /// Build and install a service for a channel that has none.
    ///
    /// Config remains the authority: this only ever builds what `channels.json` enables. What
    /// changes is that "was it enabled when the process started" is no longer the boundary.
    ///
    /// - Returns: `false` when the transport is unimplemented or its build failed. A channel that
    ///   already has a service also returns `false`; callers check first, this guard is the belt.
    private func buildService(for channel: ChannelId, config: ChannelListenerConfig) -> Bool {
        guard services[channel] == nil else { return false }
        guard let made = Self.makeService(
            channel: channel,
            config: config,
            dataDirectory: dataDirectory,
            mediaRoot: mediaRoot,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            logger: logger
        ) else { return false }
        plugins[channel] = made.plugin
        configs[channel] = config
        builtConfigs[channel] = config
        services[channel] = made.service
        logger.info("channel_service_built channel=\(channel.rawValue) transport=\(config.transport.rawValue)")
        return true
    }

    /// Tear a channel's service down completely.
    ///
    /// Order is load-bearing, in four steps.
    ///
    /// **Detach from `services` first, synchronously** — no `await` between reading the map and
    /// mutating it — so no other work on this actor can observe a half-removed channel or start a
    /// service on its way out. Reading it, awaiting `stop()` and only then removing it reads as one
    /// operation and is not: a pass that re-added and started the channel across those awaits would
    /// have had a *running* service dropped from the map unstopped.
    ///
    /// **Then `stop()`**, because that is what releases the `ChannelInstanceLock` and drains the
    /// intake pipeline. A service dropped without being stopped strands a lock file only this
    /// process may release, so the channel could never start again short of a restart — the failure
    /// `failStart()` exists to prevent, reintroduced one layer up.
    ///
    /// **Then `withdrawOutbound`, and the plugin last.** A message arriving in that window then
    /// resolves a real surface and fails at the transport, where it is logged, rather than resolving
    /// nil and being dropped in silence — `ChannelMessageOutputDeliverer` returns without a word on
    /// a nil surface.
    ///
    /// `configs` deliberately keeps its entry. `refreshedConfig()` has already forced `enabled`
    /// false, and the retained transport label is what `statuses()` falls back to when the config
    /// file does not decode. `builtConfigs` does not: it describes a service that no longer exists,
    /// and leaving it would report drift against a listener nobody is running.
    private func removeService(_ channel: ChannelId) async {
        guard let service = services.removeValue(forKey: channel) else { return }
        await service.stop()
        await withdrawOutbound(channel)
        plugins.removeValue(forKey: channel)
        builtConfigs.removeValue(forKey: channel)
        unbuildableConfigs.removeValue(forKey: channel)
        logger.info("channel_service_removed channel=\(channel.rawValue)")
    }

    /// Build one channel's plugin and service, or `nil` if its transport cannot be built.
    ///
    /// Shared by the boot builder and the runtime build pass so the two cannot drift — the dm-scope
    /// warning, the `notImplemented` handling and the service's construction arguments are written
    /// once.
    private static func makeService(
        channel: ChannelId,
        config: ChannelListenerConfig,
        dataDirectory: URL,
        mediaRoot: URL,
        ingress: ChannelIngressAdapter,
        dedupe: any TriggerDedupeChecking,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator?,
        logger: Logger
    ) -> (plugin: ChannelPlugin, service: ChannelListenerService)? {
        if config.dmScope == .main {
            logger.warning("channel_dm_scope_main channel=\(channel.rawValue) risks cross-peer DM leakage on multi-user channels")
        }
        let bundle: ChannelBuiltListenerBundle
        do {
            bundle = try ChannelPluginFactory.build(channel: channel, config: config, logger: logger)
        } catch ChannelTransportBuildError.notImplemented(let transport) {
            logger.warning("channel_transport_not_implemented channel=\(channel.rawValue) transport=\(transport.rawValue)")
            return nil
        } catch {
            logger.error("channel_transport_build_failed channel=\(channel.rawValue) error=\(String(describing: error))")
            return nil
        }
        let service = ChannelListenerService(
            channel: channel,
            bundle: bundle,
            dataDirectory: dataDirectory,
            mediaRoot: mediaRoot,
            ingress: ingress,
            dedupe: dedupe,
            lifecycleCoordinator: lifecycleCoordinator,
            logger: logger
        )
        return (bundle.plugin, service)
    }

    private static func buildServicesAndPlugins(
        dataDirectory: URL,
        mediaRoot: URL,
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
        for channel in ChannelId.allCases {
            guard let config = channelsFile.config(for: channel), config.enabled else { continue }
            guard let made = makeService(
                channel: channel,
                config: config,
                dataDirectory: dataDirectory,
                mediaRoot: mediaRoot,
                ingress: ingress,
                dedupe: dedupe,
                lifecycleCoordinator: lifecycleCoordinator,
                logger: logger
            ) else { continue }
            pluginMap[channel] = made.plugin
            configMap[channel] = config
            result[channel] = made.service
        }
        return (result, pluginMap, configMap)
    }
}
