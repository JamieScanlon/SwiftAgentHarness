import Foundation
import Logging
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Channel config diagnostics")
struct ChannelConfigLoaderDiagnosticTests {
    private func write(_ raw: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-cfg-\(UUID().uuidString)")
            .appendingPathComponent("channels.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: url)
        return url
    }

    /// Deleting `channels.json` is the most emphatic way an operator has of turning everything off,
    /// so it must count as a clean decode of "no channels" and reconcile the same way at runtime as
    /// it does at boot.
    @Test("an absent file is a clean decode of no channels")
    func absentFileIsClean() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-missing-\(UUID().uuidString)/channels.json")
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly)
        #expect(result.file.channels.isEmpty)
        #expect(result.diagnostics.contains { !$0.isFailure })
    }

    /// The failure this exists to prevent: malformed config and empty config used to be
    /// indistinguishable — same empty `ChannelsFile`, not one log line.
    @Test("a malformed file is a reported failure, not silence")
    func malformedIsReported() throws {
        let url = try write("{ not json")
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly == false)
        #expect(result.diagnostics.contains { $0.isFailure })
        #expect(result.diagnostics.first?.message.contains("channel_config_malformed") == true)
    }

    /// A `"slak"` typo leaves the file perfectly valid while the channel silently never appears.
    @Test("an unknown channel key is diagnosed but does not poison the decode")
    func unknownKeyDiagnosed() throws {
        let url = try write(#"{"channels":{"slack":{"enabled":true},"slak":{"enabled":true}}}"#)
        let result = ChannelConfigLoader.loadResult(from: url)
        // Decoded cleanly is what per-channel decisions gate on: one typo must not switch off
        // reporting for every channel that parsed.
        #expect(result.decodedCleanly)
        #expect(result.diagnostics.contains { $0.message.contains("channel_config_unknown_channel") })
        #expect(result.file.config(for: .slack)?.enabled == true)
    }

    /// The shape the README documents, and the shape an operator actually writes. Swift's
    /// *synthesized* decoder ignores property defaults and demands every non-Optional key, so this
    /// threw `keyNotFound(.transport)` and failed the whole file.
    @Test("a partial channel entry decodes with its documented defaults")
    func partialEntryDecodes() throws {
        let url = try write(#"{"channels":{"slack":{"enabled":true}}}"#)
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly)
        let config = try #require(result.file.config(for: .slack))
        #expect(config.enabled)
        #expect(config.transport == .mock)
        #expect(config.dmScope == .perChannelPeer)
        #expect(config.includeKnownPartySecurityPreamble)
        #expect(config.streaming.textChunkLimit == 4000)
        #expect(config.dedupe.ttlSeconds == 3600)
    }

    /// Nested objects were equally rigid: `"auth": {}` demanded all three of its keys.
    @Test("a partial nested object decodes with its documented defaults")
    func partialNestedObjectDecodes() throws {
        let url = try write(
            #"{"channels":{"slack":{"enabled":true,"auth":{},"mention":{"require_in_groups":false}}}}"#
        )
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly)
        let config = try #require(result.file.config(for: .slack))
        #expect(config.auth.dmAllowFrom.isEmpty)
        #expect(config.auth.fallbackGroupToDM == false)
        #expect(config.mention.requireInGroups == false)
        #expect(config.mention.treatUnknownAs == .noMention)
    }

    /// Forward compatibility: a value written by a newer build degrades to the documented default
    /// rather than taking the entire deployment's channel config offline.
    @Test("an unrecognised enum value falls back instead of failing the file")
    func unknownEnumValueFallsBack() throws {
        let url = try write(#"{"channels":{"slack":{"enabled":true,"dm_scope":"per-galaxy"}}}"#)
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly)
        #expect(result.file.config(for: .slack)?.dmScope == .perChannelPeer)
    }

    /// The one field that is deliberately *not* lenient. A malformed owner id decoded as `nil` would
    /// read as "no owner recorded", which is the permissive branch of the lifecycle ownership check —
    /// a typo would widen access rather than fail.
    @Test("a malformed owner account id fails the file rather than becoming nil")
    func malformedOwnerIDIsHardFailure() throws {
        let url = try write(#"{"channels":{"slack":{"enabled":true,"owner_account_id":"not-a-uuid"}}}"#)
        let result = ChannelConfigLoader.loadResult(from: url)
        #expect(result.decodedCleanly == false)
    }
}

@Suite("ChannelListenerRegistry lifecycle")
struct ChannelLifecycleRegistryTests {
    private struct Fixture {
        var registry: ChannelListenerRegistry
        var state: ChannelRuntimeStateStore
        var directory: URL
        var configURL: URL
    }

    private func makeFixture(
        channels: [String: ChannelListenerConfig],
        enabled: Bool = false
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-reg-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("channels.json")
        try JSONEncoder().encode(ChannelsFile(channels: channels)).write(to: configURL)
        let state = ChannelRuntimeStateStore(
            fileURL: directory.appendingPathComponent("channel_runtime_state.json")
        )
        let registry = ChannelListenerRegistry(
            dataDirectory: directory,
            ingress: Self.makeIngress(),
            dedupe: ChannelTestDedupe(),
            logger: Logger(label: "test"),
            enabled: enabled,
            channelsFile: ChannelsFile(channels: channels),
            configURL: configURL,
            runtimeState: state
        )
        return Fixture(registry: registry, state: state, directory: directory, configURL: configURL)
    }

    private func rewrite(_ fixture: Fixture, channels: [String: ChannelListenerConfig]) throws {
        try JSONEncoder().encode(ChannelsFile(channels: channels)).write(to: fixture.configURL)
    }

    private static func makeIngress() -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
            rateLimit: TriggerRateLimitGate(),
            initiatorBurst: TriggerInitiatorBurstGate(),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }))
        return ChannelIngressAdapter(
            dispatch: TriggerDispatchService(
                activationPolicy: policy,
                sessionRouter: router,
                promptBuilder: TriggerPromptBuilder(),
                runtime: DMScopeNoopRuntime()
            )
        )
    }

    // MARK: - statuses

    /// The regression that made the tool useless: `statuses()` read from built services, and services
    /// only exist for channels enabled at boot with an implemented transport. A channel the user had
    /// switched off was absent from the listing and answered "not configured" on lookup — which is
    /// exactly the question ("why did my Slack stop?") the tool exists to answer.
    @Test("a config-disabled channel is still reported, with no listener")
    func disabledChannelStillReported() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: false, transport: .mock),
        ])
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.configEnabled == false)
        #expect(summary.serviceBuilt == false)
        #expect(summary.running == false)
    }

    @Test("a channel absent from config is not reported")
    func absentChannelNotReported() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: false, transport: .mock),
        ])
        let statuses = await fixture.registry.statuses()
        #expect(statuses.contains { $0.channel == .telegram } == false)
    }

    @Test("an enabled mock channel builds a listener")
    func enabledChannelBuildsService() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.configEnabled)
        #expect(summary.serviceBuilt)
        #expect(summary.running == false)
    }

    @Test("the overlay is reflected in status")
    func overlayReflectedInStatus() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.runtimeDisabled)
        #expect(summary.overlayUnreadable == false)
    }

    /// Falling back to "no overlay" on a read error would mean anyone who can corrupt one byte
    /// re-enables every channel the owner disabled — the reset the store's throw exists to prevent,
    /// reintroduced one layer up.
    @Test("a corrupt overlay falls back to the last good read, not to permissive")
    func corruptOverlayUsesLastGood() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        // Prime the last-good snapshot with a successful read.
        _ = await fixture.registry.statuses()

        try Data("{ not json".utf8).write(
            to: fixture.directory.appendingPathComponent("channel_runtime_state.json")
        )
        let after = await fixture.registry.statuses()
        let summary = try #require(after.first { $0.channel == .slack })
        #expect(summary.runtimeDisabled, "a corrupt overlay must not un-pause a channel")
        #expect(summary.overlayUnreadable)
    }

    // MARK: - reconcile

    @Test("a channel dropped from config is reported as removed")
    func removedFromConfigReported() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        try rewrite(fixture, channels: [:])
        let report = await fixture.registry.reconcile()
        #expect(report.removedFromConfig.contains(.slack))
    }

    /// Reconcile moves listeners between started and stopped; it does not rebuild a service, so a
    /// changed transport or credential needs a restart. Saying so beats appearing to have applied it.
    @Test("a non-lifecycle config change is reported as requiring a restart")
    func configDriftReported() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock, platformIdentity: "bot-a"),
        ])
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock, platformIdentity: "bot-b"),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.requiresRestart.contains(.slack))
    }

    /// Flipping only `enabled` is the one change reconcile *can* apply, so it must not be mistaken
    /// for drift that needs a restart.
    @Test("flipping only the enabled flag is not reported as requiring a restart")
    func enabledFlipIsNotDrift() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: false, transport: .mock),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.requiresRestart.contains(.slack) == false)
    }

    /// Before the registry became mutable this reported `requiresRestart` and the operator had to
    /// bounce the gateway — `services` was built once, in `init`.
    @Test("a channel newly enabled in config is built and started by reconcile")
    func newlyEnabledChannelIsBuilt() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)],
            enabled: true
        )
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.built.contains(.slack))
        #expect(report.started.contains(.slack))
        #expect(report.requiresRestart.contains(.slack) == false)

        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.serviceBuilt)
        #expect(summary.running)
        await fixture.registry.stop()
    }

    /// Building is "make the process match config"; the overlay still attenuates. A channel the
    /// owner paused must be *built* — so status can say `serviceBuilt: true, running: false` rather
    /// than "there is no such listener" — and left stopped.
    @Test("a newly enabled channel the overlay holds off is built but not started")
    func newlyEnabledChannelHeldOffIsBuiltNotStarted() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)],
            enabled: true
        )
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.built.contains(.slack))
        #expect(report.started.contains(.slack) == false)

        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.serviceBuilt)
        #expect(summary.running == false)
        #expect(summary.runtimeDisabled)
        await fixture.registry.stop()
    }

    /// `enabled: false` is the process-wide "no channel listeners here" switch. Building a transport
    /// nothing will ever start is waste that also makes `serviceBuilt: true` lie.
    /// Building follows config; starting follows `desiredState`. Boot builds config-enabled channels
    /// regardless of the process-wide switch, so the runtime half must too — otherwise `serviceBuilt`
    /// depends on whether the channel was enabled before or after process start.
    @Test("a globally disabled registry builds a service but does not start it")
    func disabledRegistryBuildsButDoesNotStart() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)],
            enabled: false
        )
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.built.contains(.slack))
        #expect(report.started.isEmpty)
        #expect(report.buildFailed.isEmpty)
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.serviceBuilt)
        #expect(summary.running == false)
    }

    /// What this actually proves: the gate does not deadlock, and two overlapping passes converge on
    /// one service. It does **not** prove serialization — `buildService` is synchronous, so its
    /// `services[channel] == nil` guard cannot be split by a suspension and two *unserialized*
    /// reconciles would also build once. Serialization is what keeps `removeService` and the
    /// stop/start loop from interleaving, and that is not directly covered by any test; it is argued
    /// in `reconcile()`'s doc comment and reviewed, not demonstrated.
    @Test("concurrent reconciles build a channel exactly once")
    func concurrentReconcilesBuildOnce() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)],
            enabled: true
        )
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        async let first = fixture.registry.reconcile()
        async let second = fixture.registry.reconcile()
        let (a, b) = await (first, second)
        #expect(a.diagnostics.isEmpty)
        #expect(b.diagnostics.isEmpty)
        // Exactly one pass may build it. Two services would mean two listeners behind one instance
        // lock and duplicate ingestion of every inbound message.
        #expect(a.built.count + b.built.count == 1)
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.serviceBuilt)
        #expect(summary.running)
        await fixture.registry.stop()
    }

    /// An absent `channels.json` is a clean decode of "no channels" — the emphatic operator switch —
    /// but it is also what a rename-based editor save looks like for a moment. Stopping on that read
    /// is recoverable; destroying every service is not, because nothing schedules the reconcile that
    /// would rebuild them.
    @Test("a missing config file stops channels but does not tear them down")
    func missingConfigFileStopsButDoesNotTearDown() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        await fixture.registry.start()
        try FileManager.default.removeItem(at: fixture.configURL)

        let report = await fixture.registry.reconcile()
        #expect(report.removedFromConfig.contains(.slack))
        // The half the guard must preserve: a missing file still *stops*. Without this a regression
        // that made a missing file a pure no-op — leaving the listener running — would pass.
        #expect(report.stopped.contains(.slack))
        let remaining = await fixture.registry.configuredChannels()
        #expect(remaining.contains(.slack))
        let service = await fixture.registry.service(for: .slack)
        let stillRunning = await service?.isRunning
        #expect(stillRunning == false)
        await fixture.registry.stop()
    }

    /// An unimplemented transport is not fixed by a restart, so it must not be reported as needing
    /// one — which is the whole reason `buildFailed` is a separate list.
    @Test("a channel with an unimplemented transport reports buildFailed, not requiresRestart")
    func unimplementedTransportReportsBuildFailed() async throws {
        let fixture = try makeFixture(
            channels: ["discord": ChannelListenerConfig(enabled: false, transport: .discord)],
            enabled: true
        )
        try rewrite(fixture, channels: [
            "discord": ChannelListenerConfig(enabled: true, transport: .discord),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.buildFailed.contains(.discord))
        #expect(report.built.contains(.discord) == false)
        #expect(report.requiresRestart.contains(.discord) == false)
    }

    /// Dropping the service from the map without stopping it would strand the instance lock file,
    /// which only this process may release — the channel could then never start again short of a
    /// restart.
    @Test("a channel dropped from config is torn down, not just stopped")
    func removedFromConfigIsTornDown() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        await fixture.registry.start()
        let running = await fixture.registry.statuses()
        #expect(running.first { $0.channel == .slack }?.running == true)

        try rewrite(fixture, channels: [:])
        let report = await fixture.registry.reconcile()
        #expect(report.removedFromConfig.contains(.slack))
        // Not "unchanged": a channel about to be destroyed is the one thing that is not, and the
        // desired/running comparison would have said so for a channel that was already stopped.
        #expect(report.unchanged.contains(.slack) == false)

        // The service itself is gone from the registry's maps. `statuses()` iterating config would
        // report an empty list either way — it did so before teardown existed — so it proves
        // nothing on its own.
        let remaining = await fixture.registry.configuredChannels()
        #expect(remaining.isEmpty)
        let after = await fixture.registry.statuses()
        #expect(after.isEmpty)

        // The teardown's `stop()` released the instance lock. Asserted on the file rather than by
        // re-acquiring: `tryAcquire` is idempotent for the holding process, so a re-acquire would
        // succeed whether or not the release happened.
        let lockURL = ChannelInstanceLock.lockURL(
            dataDirectory: fixture.directory,
            channel: .slack,
            platformIdentity: "mock-bot"
        )
        #expect(FileManager.default.fileExists(atPath: lockURL.path) == false)

        // Nothing left for an outbound deliverer to resolve to.
        let plugin = await fixture.registry.plugin(for: .slack)
        #expect(plugin == nil)
    }

    @Test("a malformed config suppresses drift reporting rather than acting on garbage")
    func malformedConfigSuppressesDrift() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        try Data("{ not json".utf8).write(to: fixture.configURL)
        let report = await fixture.registry.reconcile()
        #expect(report.removedFromConfig.isEmpty)
        #expect(report.requiresRestart.isEmpty)
        #expect(report.diagnostics.contains { $0.isFailure })
    }

    @Test("reload on an unknown channel reports noService rather than throwing")
    func reloadUnknownChannel() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        let outcome = await fixture.registry.reload(channel: .telegram)
        #expect(outcome == .noService)
    }

    /// The defect the whole overlay exists to prevent: "the owner paused Slack and it kept ingesting
    /// anyway." Nothing else in this suite calls `start()`.
    @Test("start does not run a channel the overlay is holding off")
    func startHonoursOverlay() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        await fixture.registry.start()
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.running == false)
        #expect(summary.runtimeDisabled)
        // Nothing was started, so this releases nothing — it is here so the test cannot leave a
        // listener behind if the assertion above ever starts failing for the wrong reason.
        await fixture.registry.stop()
    }

    /// The control for the test above. Without it, "did not start" proves nothing — a registry that
    /// never starts anything would pass either way.
    @Test("start runs a channel the overlay permits")
    func startRunsPermittedChannel() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        await fixture.registry.start()
        let statuses = await fixture.registry.statuses()
        let summary = try #require(statuses.first { $0.channel == .slack })
        #expect(summary.running)
        await fixture.registry.stop()
    }

    /// A reload that restarts a paused channel is a silent un-pause.
    @Test("reload stops but refuses to restart a channel the overlay is holding off")
    func reloadHeldOff() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        try fixture.state.setDisabled(channel: .slack, disabled: true, changedBy: .owner(accountID: nil))
        let outcome = await fixture.registry.reload(channel: .slack)
        #expect(outcome == .heldOff)

        let statuses = await fixture.registry.statuses()
        #expect(statuses.first { $0.channel == .slack }?.running == false)
    }

    @Test("reload restarts a channel config and overlay both permit")
    func reloadRestarts() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            enabled: true
        )
        let outcome = await fixture.registry.reload(channel: .slack)
        #expect(outcome == .restarted)
        await fixture.registry.stop()
    }

    @Test("reload is a no-op when the registry is globally disabled")
    func reloadRegistryDisabled() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let outcome = await fixture.registry.reload(channel: .slack)
        #expect(outcome == .registryDisabled)
    }

    /// `ChannelListenerService.lifecycleEpoch`, exercised.
    ///
    /// Without the guard the resumed `start()` attaches a supervisor to a transport the interleaved
    /// `stop()` has already torn down and unlocked: a listener that is running, holds no instance
    /// lock, and — now that the registry can drop services — is unreachable from anything that would
    /// stop it, so it ingests until the process exits.
    @Test("a stop during an in-flight start unwinds instead of attaching a supervisor")
    func stopDuringStartUnwinds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-svc-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ChannelListenerConfig(enabled: true, transport: .mock)
        let real = try ChannelPluginFactory.build(
            channel: .slack,
            config: config,
            logger: Logger(label: "test")
        )
        let gate = ChannelStartGate()
        let gated = GatedSupervisedListener(inner: real.listener, gate: gate)
        let bundle = ChannelBuiltListenerBundle(
            plugin: real.plugin,
            listener: gated,
            parseRawEvent: real.parseRawEvent
        )
        let service = ChannelListenerService(
            channel: .slack,
            bundle: bundle,
            dataDirectory: directory,
            mediaRoot: directory.appendingPathComponent("media", isDirectory: true),
            ingress: Self.makeIngress(),
            dedupe: ChannelTestDedupe(),
            logger: Logger(label: "test")
        )

        let startTask = Task { await service.start() }
        // Returns once `start()` is suspended inside `prepareSupervisedTransport()`, holding the
        // instance lock and with its pipeline installed.
        await gate.waitUntilEntered()
        await service.stop()
        await gate.release()
        await startTask.value

        let running = await service.isRunning
        #expect(running == false)
        // The interleaved `stop()` released the lock; the superseded `start()` must not have taken
        // it again on the way out.
        let lockURL = ChannelInstanceLock.lockURL(
            dataDirectory: directory,
            channel: .slack,
            platformIdentity: "mock-bot"
        )
        #expect(FileManager.default.fileExists(atPath: lockURL.path) == false)
        // The connect *succeeded* — the gate released it — so a superseded start that merely returns
        // leaves an open transport with no supervisor and nobody holding it, and the next `start()`
        // opens a second one under the same bot identity. Neither assertion above can see that:
        // `isRunning` reads `supervisor`, and the lock was released by `stop()` either way.
        #expect(gated.disconnectCount == 1)
    }
}

/// Holds `prepareSupervisedTransport()` open until the test releases it.
private actor ChannelStartGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the listener under test.
    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Forwards every listener member to a real one and gates only the connect.
///
/// A from-scratch conformer would restate eleven members and quietly invent behaviour for ten of
/// them; forwarding keeps the double honest — everything except the suspension point under test is
/// the production path.
private final class GatedSupervisedListener: ChannelSupervisedListening, @unchecked Sendable {
    private let inner: any ChannelSupervisedListening
    private let gate: ChannelStartGate
    /// `Mutex` because that is this codebase's idiom for a lock an `async`-facing type owns; the
    /// critical section itself is synchronous and released before the forwarded `await`.
    private let disconnects = Mutex(0)

    var disconnectCount: Int { disconnects.withLock { $0 } }

    init(inner: any ChannelSupervisedListening, gate: ChannelStartGate) {
        self.inner = inner
        self.gate = gate
    }

    var id: ChannelId { inner.id }
    var platformIdentity: String { inner.platformIdentity }
    var state: ChannelListenerState { inner.state }
    var fatalError: ChannelFatalError? { inner.fatalError }
    var config: ChannelListenerConfig { inner.config }

    func prepareSupervisedTransport() async throws {
        await gate.enterAndWait()
        try await inner.prepareSupervisedTransport()
    }

    func transportForSupervision() -> any ChannelTransport { inner.transportForSupervision() }
    func markTransportConnected() { inner.markTransportConnected() }
    func markTransportDisconnected() { inner.markTransportDisconnected() }
    func setFatal(_ error: ChannelFatalError) { inner.setFatal(error) }

    func connect() async throws -> ChannelConnectResult { try await inner.connect() }
    func disconnect() async {
        disconnects.withLock { $0 += 1 }
        await inner.disconnect()
    }
    func onTrigger(_ handler: @escaping ChannelTriggerHandler) -> @Sendable () -> Void {
        inner.onTrigger(handler)
    }
    func sendTyping(chatId: String) async { await inner.sendTyping(chatId: chatId) }
    func react(messageId: String, emoji: String) async {
        await inner.react(messageId: messageId, emoji: emoji)
    }
    func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult {
        await inner.send(message)
    }
}
