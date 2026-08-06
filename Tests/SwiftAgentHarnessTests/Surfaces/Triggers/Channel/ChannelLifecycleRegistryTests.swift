import Foundation
import Logging
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

    /// Services are built once, in `init`. A channel the operator has since switched on has nothing
    /// to start, and without this would reconcile to "unchanged" and report nothing at all.
    @Test("a channel newly enabled in config needs a restart to get a listener")
    func newlyEnabledChannelNeedsRestart() async throws {
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: false, transport: .mock),
        ])
        try rewrite(fixture, channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock),
        ])
        let report = await fixture.registry.reconcile()
        #expect(report.requiresRestart.contains(.slack))
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
}
