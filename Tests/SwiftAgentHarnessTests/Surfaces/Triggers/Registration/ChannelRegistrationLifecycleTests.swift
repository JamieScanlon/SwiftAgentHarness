import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Channel lifecycle registration")
struct ChannelRegistrationLifecycleTests {
    private struct Fixture {
        var registration: TriggerRegistrationService
        var state: ChannelRuntimeStateStore
        var directory: URL
    }

    private func makeFixture(
        channels: [String: ChannelListenerConfig]? = ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
        rawConfig: String? = nil,
        withStateStore: Bool = true,
        withConfigURL: Bool = true,
        applier: ChannelLifecycleApplierHolder? = nil,
        tenancy: TenancyPolicySettings = .disabled
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("channels.json")
        if let rawConfig {
            try Data(rawConfig.utf8).write(to: configURL)
        } else if let channels {
            let encoder = JSONEncoder()
            try encoder.encode(ChannelsFile(channels: channels)).write(to: configURL)
        }
        let state = ChannelRuntimeStateStore(
            fileURL: directory.appendingPathComponent("channel_runtime_state.json")
        )
        let registration = TriggerRegistrationService(
            store: ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json")),
            channelState: withStateStore ? state : nil,
            channelConfigURL: withConfigURL ? configURL : nil,
            channelApply: applier,
            tenancy: tenancy,
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            logger: Logger(label: "test")
        )
        return Fixture(registration: registration, state: state, directory: directory)
    }

    private func ownerAuthority(_ accountID: UUID? = nil) -> RegistrationAuthority {
        .localCLI(ownerAccountID: accountID)
    }

    // MARK: - Authority

    /// The verdict is reused from `allowsRegistration(_:kind: .channel)` rather than restated. A
    /// creator that may not register a channel must not be able to silence one either — silencing is
    /// the more attacker-interesting direction, since the channel that stops is also the channel
    /// that stops reporting.
    @Test("a main agent cannot pause a channel")
    func agentDenied() async throws {
        let fixture = try makeFixture()
        await #expect(throws: TriggerRegistrationError.kindNotRegisterable(kind: .channel, creator: "agent")) {
            try await fixture.registration.setChannelEnabled(
                channel: .slack,
                enabled: false,
                authority: TriggerRegistrationTestSupport.agentAuthority(conversation: UUID())
            )
        }
        let overlay = try fixture.state.load()
        #expect(overlay.isEmpty)
    }

    @Test("a sub-agent cannot pause a channel")
    func subAgentDenied() async throws {
        let fixture = try makeFixture()
        let conversation = UUID()
        let authority = RegistrationAuthority(
            creator: .subAgent(conversationID: conversation, lineageRoot: conversation, ownerAccountID: nil),
            surface: .tool
        )
        await #expect(throws: TriggerRegistrationError.kindNotRegisterable(kind: .channel, creator: "sub-agent")) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: false, authority: authority)
        }
    }

    @Test("an owner can pause a configured channel")
    func ownerMayPause() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority()
        )
        #expect(result.entry.disabled)
        let overlay = try fixture.state.load()
        #expect(overlay["slack"]?.disabled == true)
    }

    // MARK: - Config is authoritative in one direction

    /// The overlay may only attenuate. Turning a channel on is the decision that carries the
    /// credentials and the inbound socket, and it belongs in config.
    @Test("enable is refused when config disables the channel")
    func enableRefusedWhenConfigDisabled() async throws {
        let fixture = try makeFixture(channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)])
        await #expect(throws: TriggerRegistrationError.channelDisabledInConfig(channel: "slack")) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: true, authority: ownerAuthority())
        }
    }

    /// A channel absent from `channels.json` is `notFound`, not `channelDisabledInConfig` — there is
    /// nothing to enable, and the distinction is what lets the HTTP surface answer 404.
    @Test("enable is refused for a channel absent from config")
    func enableRefusedWhenAbsent() async throws {
        let fixture = try makeFixture(channels: [:])
        await #expect(throws: TriggerRegistrationError.notFound) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: true, authority: ownerAuthority())
        }
    }

    /// The asymmetry that shipped and had to be fixed: only the *enable* branch checked config, so
    /// pausing a nonexistent channel returned success and wrote an overlay row for it — while a
    /// status read of the same name answered "not configured", because status reports from config.
    @Test("pause is refused for a channel absent from config, and writes nothing")
    func pauseRefusedWhenAbsent() async throws {
        let fixture = try makeFixture(channels: [:])
        await #expect(throws: TriggerRegistrationError.notFound) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: false, authority: ownerAuthority())
        }
        let overlay = try fixture.state.load()
        #expect(overlay.isEmpty)
    }

    /// Strict tenancy forbids the anonymous local-trust surfaces: "whoever can reach the data
    /// directory" is not a principal in a multi-tenant deployment. Distinct from the owner-mismatch
    /// case below, which is about a *wrong* principal rather than an absent one.
    @Test("strict tenancy refuses an anonymous caller even when config records no owner")
    func strictTenancyRefusesAnonymousCaller() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            tenancy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )
        await #expect(throws: TriggerRegistrationError.channelNotOwned(channel: "slack")) {
            try await fixture.registration.setChannelEnabled(
                channel: .slack,
                enabled: false,
                authority: ownerAuthority(nil)
            )
        }
    }

    /// The regression this replaced: requiring `configOwner` to be present under strict tenancy gave
    /// a correctly authenticated owner `channel_not_owned` on every channel, because
    /// `owner_account_id` is optional and undocumented. An unrecorded owner means unpartitioned.
    @Test("strict tenancy allows an authenticated caller when config records no owner")
    func strictTenancyAllowsAuthenticatedCallerOnUnownedChannel() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock)],
            tenancy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )
        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority(UUID())
        )
        #expect(result.entry.disabled)
    }

    /// A malformed config is not "no owner recorded" — it is an ACL that cannot be read, and reading
    /// it permissively is the failure this refuses.
    @Test("a malformed channels.json refuses the mutation instead of skipping the ACL")
    func malformedConfigRefuses() async throws {
        let fixture = try makeFixture(rawConfig: "{ not json")
        await #expect(throws: TriggerRegistrationError.channelConfigUnreadable(channel: "slack")) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: false, authority: ownerAuthority())
        }
    }

    @Test("a deployment with no overlay store reports unavailable, not unauthorized")
    func noStoreIsUnavailable() async throws {
        let fixture = try makeFixture(withStateStore: false)
        await #expect(throws: TriggerRegistrationError.channelLifecycleUnavailable) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: false, authority: ownerAuthority())
        }
    }

    /// Both halves or neither: without the config URL there is no ACL to check, and a mutation that
    /// skips the ownership comparison is worse than one that is unavailable.
    @Test("a store with no config URL is unavailable rather than unchecked")
    func noConfigURLIsUnavailable() async throws {
        let fixture = try makeFixture(withConfigURL: false)
        await #expect(throws: TriggerRegistrationError.channelLifecycleUnavailable) {
            try await fixture.registration.setChannelEnabled(channel: .slack, enabled: false, authority: ownerAuthority())
        }
    }

    // MARK: - Ownership

    @Test("a mismatched owner account is refused")
    func ownerMismatchRefused() async throws {
        let configOwner = UUID()
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: configOwner)]
        )
        await #expect(throws: TriggerRegistrationError.channelNotOwned(channel: "slack")) {
            try await fixture.registration.setChannelEnabled(
                channel: .slack,
                enabled: false,
                authority: ownerAuthority(UUID())
            )
        }
    }

    @Test("a matching owner account is allowed")
    func ownerMatchAllowed() async throws {
        let owner = UUID()
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: owner)]
        )
        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority(owner)
        )
        #expect(result.entry.disabled)
    }

    /// Under `.disabled` tenancy a missing id on either side falls back to creator class, which is
    /// what keeps single-tenant deployments — where nothing carries an account id at all — working.
    @Test("missing account ids fall back to creator class under disabled tenancy")
    func missingIDsPermittedWhenTenancyOff() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: UUID())]
        )
        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority(nil)
        )
        #expect(result.entry.disabled)
    }

    @Test("strict tenancy requires both ids to be present and equal")
    func strictTenancyRequiresBothIDs() async throws {
        let fixture = try makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: UUID())],
            tenancy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )
        await #expect(throws: TriggerRegistrationError.channelNotOwned(channel: "slack")) {
            try await fixture.registration.setChannelEnabled(
                channel: .slack,
                enabled: false,
                authority: ownerAuthority(nil)
            )
        }
    }

    // MARK: - Apply

    /// A pause that persists an intent, reports success, and leaves the channel ingesting until the
    /// next restart is the wrong failure for a control whose whole point is taking effect now. When
    /// no applier is attached the call still succeeds, but says so.
    @Test("no applier reports appliedToRunningProcess=false")
    func noApplierReportsUnapplied() async throws {
        let fixture = try makeFixture()
        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority()
        )
        #expect(result.appliedToRunningProcess == false)
        #expect(result.summary.contains("next start"))
    }

    @Test("an installed applier runs and is reported")
    func applierRuns() async throws {
        let box = ChannelApplyCountBox()
        let holder = ChannelLifecycleApplierHolder()
        holder.install { await box.increment() }
        let fixture = try makeFixture(applier: holder)

        let result = try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority()
        )
        #expect(result.appliedToRunningProcess)
        let count = await box.count
        #expect(count == 1)
    }

    @Test("a refused mutation does not run the applier")
    func refusedMutationSkipsApplier() async throws {
        let box = ChannelApplyCountBox()
        let holder = ChannelLifecycleApplierHolder()
        holder.install { await box.increment() }
        let fixture = try makeFixture(applier: holder)

        _ = try? await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: TriggerRegistrationTestSupport.agentAuthority(conversation: UUID())
        )
        let count = await box.count
        #expect(count == 0)
    }

    // MARK: - Reads

    /// `RegistrationCreator` carries conversation, lineage-root and owner-account UUIDs plus whatever
    /// free text the caller wrote into `reason`. A listing hands out the creator *class* and nothing
    /// else, for the same reason `listWebhooks` is filtered and redacted.
    @Test("the overlay listing redacts the creator to a label")
    func listingRedactsCreator() async throws {
        let fixture = try makeFixture()
        try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority(UUID()),
            reason: "secret-sounding reason"
        )
        let rows = try fixture.registration.channelRuntimeState(authority: ownerAuthority())
        let row = try #require(rows.first)
        #expect(row.channel == "slack")
        #expect(row.disabled)
        #expect(row.changedByLabel == "owner")
    }

    /// Non-vacuous by construction: the same overlay file is read through two services, one wired
    /// and one not. Asserting emptiness alone would hold even if the store were being read.
    @Test("the overlay listing is empty when no store is wired, and not otherwise")
    func listingEmptyWithoutStore() async throws {
        let fixture = try makeFixture()
        try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority()
        )
        let wired = try fixture.registration.channelRuntimeState(authority: ownerAuthority())
        #expect(wired.count == 1)

        let unwired = TriggerRegistrationService(
            store: ScheduledTaskStore(fileURL: fixture.directory.appendingPathComponent("tasks.json")),
            channelState: nil,
            channelConfigURL: fixture.directory.appendingPathComponent("channels.json"),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            logger: Logger(label: "test")
        )
        let rows = try unwired.channelRuntimeState(authority: ownerAuthority())
        #expect(rows.isEmpty)
    }

    /// The scoping half of the listing. `ownerAuthority()` with no account id is *unscoped* by
    /// design (single-tenant), so a test that only reads back through it exercises the redaction and
    /// never the filter — inverting the filter predicate would still pass.
    @Test("one owner's pause is not listed to another owner")
    func listingIsOwnerScoped() async throws {
        let owner = UUID()
        let other = UUID()
        let fixture = try makeFixture(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: owner),
        ])
        try await fixture.registration.setChannelEnabled(
            channel: .slack,
            enabled: false,
            authority: ownerAuthority(owner)
        )
        let mine = try fixture.registration.channelRuntimeState(authority: ownerAuthority(owner))
        #expect(mine.count == 1)

        let theirs = try fixture.registration.channelRuntimeState(authority: ownerAuthority(other))
        #expect(theirs.isEmpty)
    }
}

actor ChannelApplyCountBox {
    private(set) var count = 0
    func increment() { count += 1 }
}
