import Foundation
import Logging
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

/// HTTP-level coverage for the four `/api/channels` routes.
///
/// The unit tests underneath this cover `setChannelEnabled` in isolation, and they cannot see the
/// thing that actually went wrong here: authority is derived from a *task-local* the Vapor
/// middleware binds, so whether a caller is a principal is a property of the request, not of any
/// value passed into the endpoint. The first version of this surface read that task-local inside the
/// handler and minted `.owner(accountID: nil)` for anonymous callers — an unauthenticated POST to a
/// gateway on `0.0.0.0` could silence a channel and write an audit row attributing it to "owner",
/// and a model with a shell tool could `curl` the exact capability the `channel` tool withholds.
/// Only a test that goes through the router can hold that shut.
@Suite("Trigger channel admin routes")
struct TriggerChannelAdminRouteTests {
    private struct Fixture {
        var api: APILayer
        var state: ChannelRuntimeStateStore
        var directory: URL
        var applied: ChannelApplyRecorder
    }

    /// Records whether the live-apply step ran, so `appliedToRunningProcess` is checked against
    /// something rather than taken on faith.
    final class ChannelApplyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var applyCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func makeFixture(
        channels: [String: ChannelListenerConfig],
        strictTenancy: Bool = false
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chan-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("channels.json")
        try JSONEncoder().encode(ChannelsFile(channels: channels)).write(to: configURL)

        let state = ChannelRuntimeStateStore(
            fileURL: directory.appendingPathComponent("channel_runtime_state.json")
        )
        let applied = ChannelApplyRecorder()
        let applier = ChannelLifecycleApplierHolder()
        applier.install { applied.record() }

        let registration = TriggerRegistrationService(
            store: ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json")),
            channelState: state,
            channelConfigURL: configURL,
            channelApply: applier,
            tenancy: strictTenancy
                ? TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
                : .disabled,
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            logger: Logger(label: "test")
        )
        let registry = ChannelListenerRegistry(
            dataDirectory: directory,
            ingress: Self.makeIngress(),
            dedupe: ChannelTestDedupe(),
            logger: Logger(label: "test"),
            enabled: false,
            channelsFile: ChannelsFile(channels: channels),
            configURL: configURL,
            runtimeState: state
        )

        let api = APILayer(port: 0)
        await api.setTriggerChannelAdminRegistrar(
            TriggerChannelAdminRouteRegistrar(
                registration: registration,
                channelRegistry: registry,
                logger: Logger(label: "test")
            )
        )
        if strictTenancy {
            await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
        } else {
            // Token settings without strict tenancy: the deployment shape the defect lived in. A
            // bearer still resolves to a principal; nothing *requires* one at the tenancy layer.
            await api.setAPIAccessTokenAuthenticationSettings(
                APILayerRESTRouteTestSupport.strictTenancyAuthSettings
            )
        }
        return Fixture(api: api, state: state, directory: directory, applied: applied)
    }

    private static func makeIngress() -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
            rateLimit: TriggerRateLimitGate(),
            initiatorBurst: TriggerInitiatorBurstGate(),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        return ChannelIngressAdapter(
            dispatch: TriggerDispatchService(
                activationPolicy: policy,
                sessionRouter: TriggerSessionRouter(
                    sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })
                ),
                promptBuilder: TriggerPromptBuilder(),
                runtime: DMScopeNoopRuntime()
            )
        )
    }

    /// `withApp` takes a plain (non-`@Sendable`) closure, so this wrapper can hold one too — which
    /// is what lets the fixture, an actor and two reference types, be captured without ceremony.
    private func withRoutes(
        _ fixture: Fixture,
        _ perform: (Application) async throws -> Void
    ) async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        try await withApp { app in
            await fixture.api.configureRoutesForTesting(
                app: app,
                runtimeSession: runtimeSession,
                modelProvider: APILayerRESTStubModelProvider()
            )
            try await perform(app)
        }
    }

    private func body(_ raw: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: raw)
        return try #require(object as? [String: Any])
    }

    private static let slackEnabled = ["slack": ChannelListenerConfig(enabled: true, transport: .mock)]

    // MARK: - Authority

    /// The regression that matters most on this surface. `tenancyRespondIfCreateMutationForbidden`
    /// returns `nil` on its first line when `requireAuthenticatedOwnerOnMutations` is false — the
    /// *default* — so the tenancy helper alone permits this request. What refuses it is the
    /// handler's own unconditional principal check, and this is the only test that exercises the
    /// combination.
    @Test("an anonymous pause is refused, and writes no overlay")
    func anonymousPauseRefused() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
        // Not merely rejected — nothing was persisted, and the live listener was never touched.
        #expect(try fixture.state.load().isEmpty)
        #expect(fixture.applied.applyCount == 0)
    }

    @Test("an anonymous resume is refused")
    func anonymousResumeRefused() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/resume", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    /// A bearer that does not validate is not a principal. Without this, "authenticated" could mean
    /// "sent an Authorization header".
    @Test("a pause with an unverifiable bearer token is refused")
    func forgedBearerRefused() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: "Bearer not-a-real-token")
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    /// The legacy header predates token auth and must not be a way back in.
    @Test("the legacy owner header does not authenticate a pause")
    func legacyOwnerHeaderRefused() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Authenticated-Owner", value: UUID().uuidString)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    // MARK: - Happy path

    @Test("an authenticated pause persists the overlay and applies it to the running process")
    func authenticatedPauseSucceeds() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try self.body(Data(res.body.readableBytesView))
                #expect(json["channel"] as? String == "slack")
                #expect(json["paused"] as? Bool == true)
                // This surface runs inside the gateway, so the change is live before the response
                // is written — unlike the CLI's copy of the same field.
                #expect(json["appliedToRunningProcess"] as? Bool == true)
            })
        }
        let overlay = try fixture.state.load()
        let entry = try #require(overlay["slack"])
        #expect(entry.channel == "slack")
        #expect(entry.disabled)
        #expect(fixture.applied.applyCount == 1)
    }

    @Test("an authenticated resume clears the overlay hold")
    func authenticatedResumeSucceeds() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.POST, "/api/channels/slack/resume", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try self.body(Data(res.body.readableBytesView))["paused"] as? Bool == false)
            })
        }
        #expect(try fixture.state.load()["slack"]?.disabled == false)
    }

    // MARK: - Attenuate, never amplify

    /// The overlay may only hold a permitted channel off. Resuming past an operator's
    /// `enabled: false` would make a runtime client authoritative over `channels.json`.
    @Test("resume cannot override a config-disabled channel")
    func resumeCannotOverrideConfig() async throws {
        let fixture = try await makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)]
        )
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/resume", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                #expect(try self.body(Data(res.body.readableBytesView))["message"] as? String == "channel_disabled_in_config")
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    /// Pause used to be the unchecked direction: only the enable branch verified the channel exists,
    /// so pausing an unconfigured channel returned 200 and wrote an overlay row for it — while
    /// `GET /api/channels/{channel}` answered 404 for the same name.
    @Test("pausing an unconfigured channel is a 404, not a phantom overlay row")
    func pauseOfUnconfiguredChannelIsNotFound() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        let absent = try #require(ChannelId.allCases.first { $0 != .slack })
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/\(absent.rawValue)/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
                #expect(try self.body(Data(res.body.readableBytesView))["message"] as? String == "not_found")
            })
            // The same name answers 404 on the read route, which is the consistency that was broken.
            try await app.testing().test(.GET, "/api/channels/\(absent.rawValue)", afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    @Test("an unrecognised channel name is a 400, distinct from an unconfigured one")
    func unknownChannelNameIsBadRequest() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slak/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try self.body(Data(res.body.readableBytesView))
                let message = try #require(json["message"] as? String)
                #expect(message.contains("slack"))
            })
        }
    }

    // MARK: - Tenant partitioning

    /// `owner_account_id` in `channels.json` partitions a channel. A different authenticated
    /// principal is a 403 rather than a silent success.
    @Test("a channel owned by another account cannot be paused")
    func crossTenantPauseForbidden() async throws {
        let owner = UUID()
        let fixture = try await makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: owner)]
        )
        let intruder = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: intruder)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
                #expect(try self.body(Data(res.body.readableBytesView))["message"] as? String == "channel_not_owned")
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    @Test("the recorded owner can pause their own channel")
    func sameTenantPauseAllowed() async throws {
        let owner = UUID()
        let fixture = try await makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: true, transport: .mock, ownerAccountID: owner)]
        )
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: owner)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
        #expect(try fixture.state.load()["slack"]?.disabled == true)
    }

    /// An earlier version additionally required `owner_account_id` to be *present* under strict
    /// tenancy, so a correctly authenticated owner got `channel_not_owned` on every channel —
    /// `owner_account_id` is optional and undocumented, so that was every deployment. A channel with
    /// no recorded owner is unpartitioned, not forbidden.
    @Test("strict tenancy does not forbid an unpartitioned channel")
    func strictTenancyAllowsUnownedChannel() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled, strictTenancy: true)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
        #expect(try fixture.state.load()["slack"]?.disabled == true)
    }

    @Test("strict tenancy still refuses an anonymous pause")
    func strictTenancyRefusesAnonymous() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled, strictTenancy: true)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.POST, "/api/channels/slack/pause", afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
        #expect(try fixture.state.load().isEmpty)
    }

    // MARK: - Read routes

    /// Read is `tenancy_guard: none` by design — a channel is operator config, not a per-tenant
    /// partition, the same posture as `/api/status`. What makes that safe is the projection.
    @Test("the listing reports a channel the operator switched off")
    func listingIncludesDisabledChannel() async throws {
        let fixture = try await makeFixture(
            channels: ["slack": ChannelListenerConfig(enabled: false, transport: .mock)]
        )
        try await withRoutes(fixture) { app in
            try await app.testing().test(.GET, "/api/channels", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try self.body(Data(res.body.readableBytesView))
                let channels = try #require(json["channels"] as? [[String: Any]])
                let slack = try #require(channels.first { $0["channel"] as? String == "slack" })
                #expect(slack["configEnabled"] as? Bool == false)
                #expect(slack["running"] as? Bool == false)
            })
        }
    }

    /// The wire shape is deliberately a projection rather than `ChannelStatusSummary` made
    /// `Codable`, and it carries the fatal *code* rather than the message — the message is
    /// `String(describing:)` of a transport error and can carry a URL or a rejected token. An
    /// unauthenticated GET must not become a credential leak.
    @Test("the status projection exposes no platform identity or fatal message")
    func statusProjectionIsNarrow() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        try await withRoutes(fixture) { app in
            try await app.testing().test(.GET, "/api/channels/slack", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try self.body(Data(res.body.readableBytesView))
                #expect(json["channel"] as? String == "slack")
                // `lastFatalCode` is optional and absent when there is no fatal, so the presence
                // assertion goes on the fields that are always written.
                #expect(json.keys.contains("state"))
                #expect(json.keys.contains("transport"))
                for leaked in ["token", "botToken", "auth", "primaryUser", "fatalMessage", "lastFatalMessage", "ownerAccountID"] {
                    #expect(json.keys.contains(leaked) == false)
                }
            })
        }
    }

    /// `reload` is deliberately absent: `ChannelListenerRegistry.reload(channel:)` bypasses
    /// `setChannelEnabled`, so exposing it would need its own authority gate and audit row. Nothing
    /// creates or deletes a channel either — `channels.json` stays operator-owned.
    @Test("no route creates, deletes, or reloads a channel")
    func absentRoutesStayAbsent() async throws {
        let fixture = try await makeFixture(channels: Self.slackEnabled)
        let auth = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: UUID())
        try await withRoutes(fixture) { app in
            // No handler at all: unambiguously a 404.
            try await app.testing().test(.POST, "/api/channels/slack/reload", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
            // A path that exists for a *different* method. The invariant is that the capability is
            // absent, not which of 404/405 the router picks — asserting the code would be a test of
            // Vapor's routing rather than of this surface.
            try await app.testing().test(.POST, "/api/channels", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status != .ok)
            })
            try await app.testing().test(.DELETE, "/api/channels/slack", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .authorization, value: auth)
            }, afterResponse: { res async throws in
                #expect(res.status != .ok)
            })
        }
        // And nothing an absent route could have done was done.
        #expect(try fixture.state.load().isEmpty)
    }
}
