import Foundation
import Logging
import Vapor

/// Operator HTTP surface for channel lifecycle — the client that can pause a channel in a
/// **running** gateway.
///
/// Phase 4a shipped two clients and neither could do that: the CLI is a separate process, so it
/// writes the overlay and the change lands at next start; the `channel` agent tool is read-only
/// because `allowsRegistration(_:kind: .channel)` denies model-driven creators. This closes it.
///
/// **Why HTTP and not a slash command.** The other candidate was a `/channel` *builtin*, where
/// `SlashCommandDispatcher` already gates `ownerOnly` on an unforgeable `isOwner`. That route needs
/// a trigger seam on `ConversationRuntimeDependencies`, which nothing else in the harness needs, and
/// channel lifecycle is an operator concern rather than a conversational one. Here the principal is
/// already bound by `ClientSessionMiddleware`, and `reconcile()` runs in-process so a pause takes
/// effect immediately.
///
/// **What is deliberately not here.** Nothing creates or deletes a channel: `channels.json` stays
/// operator-owned and is never written from a runtime surface (phase 4b). And `reload` is absent —
/// `ChannelListenerRegistry.reload(channel:)` bypasses `setChannelEnabled`, so exposing it would
/// need its own authority gate and audit row, which is a separate change rather than a fifth route.
///
/// Registered on the **`api` group**, not the raw `Application` — that is the whole point.
/// `ClientSessionMiddleware` binds `APISessionContext.authenticatedOwnerAccountID` only under
/// `/api`, so the sibling `TriggerWebhookRouteRegistrar`, which registers on `app`, gets a `nil`
/// principal by construction. Webhooks authenticate by HMAC and want that; this must not.
public struct TriggerChannelAdminRouteRegistrar: Sendable {
    let registration: TriggerRegistrationService
    let channelRegistry: ChannelListenerRegistry
    let logger: Logger

    init(
        registration: TriggerRegistrationService,
        channelRegistry: ChannelListenerRegistry,
        logger: Logger
    ) {
        self.registration = registration
        self.channelRegistry = channelRegistry
        self.logger = logger
    }

    /// Composition-root helper, mirroring ``TriggerWebhookRouteRegistrar/init(bundle:logger:)``.
    public init(bundle: TriggersRuntimeBundle, logger: Logger) {
        self.init(
            registration: bundle.registration,
            channelRegistry: bundle.channelRegistry,
            logger: logger
        )
    }

    /// Internal because `APILayerRouteDependencies` is: the canonical tenancy helpers hang off it,
    /// and per `openapi/ROUTE_INVENTORY.md` REST tenancy here is discipline-based — every new route
    /// is a site where the guard can be forgotten, so the route inventory names the helper each
    /// handler must call. Reimplementing the check locally would satisfy the reviewer and fail the
    /// invariant test, which is the correct outcome for a private copy of a shared rule.
    func register(on api: RoutesBuilder, dependencies: APILayerRouteDependencies) {
        let channelsPath = api.grouped("channels")

        // Read-only, `tenancy_guard: none`. A channel is written into this deployment's
        // `channels.json` by the operator, so there is no per-tenant partition to enforce — the same
        // posture as `/api/status` and `/api/exec-approvals/grants`. What makes it safe is
        // `ChannelStatusSummary` itself: no platform identity, no primary user, and the fatal *code*
        // rather than the message, which is `String(describing:)` of a transport error and can carry
        // a URL or a rejected token.
        channelsPath.get { [channelRegistry] _ async -> Response in
            let summaries = await channelRegistry.statuses()
            return Self.json(ChannelAdminListResponse(channels: summaries.map(ChannelAdminStatus.init)))
        }

        channelsPath.get(":channel") { [channelRegistry] req async -> Response in
            guard let channel = Self.channel(from: req) else {
                return APILayerRESTErrorResponse.error(status: .badRequest, message: Self.unknownChannelMessage)
            }
            let summaries = await channelRegistry.statuses()
            guard let summary = summaries.first(where: { $0.channel == channel }) else {
                return APILayerRESTErrorResponse.error(status: .notFound, message: "Channel not configured")
            }
            return Self.json(ChannelAdminStatus(summary))
        }

        channelsPath.post(":channel", "pause") { [self] req async -> Response in
            if let forbidden = dependencies.tenancyRespondIfCreateMutationForbidden() {
                return forbidden
            }
            return await setEnabled(req: req, enabled: false)
        }

        channelsPath.post(":channel", "resume") { [self] req async -> Response in
            if let forbidden = dependencies.tenancyRespondIfCreateMutationForbidden() {
                return forbidden
            }
            return await setEnabled(req: req, enabled: true)
        }
        // Note the guard above is necessary but NOT sufficient — it is a no-op unless strict tenancy
        // is enabled, which is not the default. `setEnabled` carries the unconditional check.
    }

    // MARK: - Mutation

    private func setEnabled(req: Request, enabled: Bool) async -> Response {
        guard let channel = Self.channel(from: req) else {
            return APILayerRESTErrorResponse.error(status: .badRequest, message: Self.unknownChannelMessage)
        }
        // Unconditional, and deliberately not delegated to the tenancy helper above.
        //
        // `tenancyRespondIfCreateMutationForbidden` returns `nil` on its first line when
        // `requireAuthenticatedOwnerOnMutations` is false, which is the *default*. Relying on it
        // alone meant an anonymous POST to a gateway bound on 0.0.0.0 minted `.owner(accountID: nil)`
        // authority, silenced any channel, and wrote an audit row attributing it to "owner". It also
        // handed the agent the exact capability the `channel` tool withholds: a model with a shell
        // tool can curl this route.
        //
        // A control-plane surface has no single-tenant convenience case worth that. The local CLI
        // stays anonymous because its credential is filesystem access to the data directory; a
        // network request has no equivalent, so it must present a token.
        guard let principal = APISessionContext.authenticatedOwnerAccountID else {
            return APILayerTenancyResponses.unauthorizedMissingOwner()
        }
        do {
            let result = try await registration.setChannelEnabled(
                channel: channel,
                enabled: enabled,
                authority: Self.authority(principal: principal),
                reason: "http-admin"
            )
            return Self.json(ChannelAdminLifecycleResponse(result))
        } catch let error as TriggerRegistrationError {
            return APILayerRESTErrorResponse.error(status: Self.status(for: error), message: error.code)
        } catch {
            logger.error("channel_admin_lifecycle_failed channel=\(channel.rawValue) error=\(String(describing: error))")
            return APILayerRESTErrorResponse.error(status: .internalServerError, message: "channel_lifecycle_failed")
        }
    }

    /// `.owner` rather than `.agent`, and the id is non-optional by construction.
    ///
    /// The caller resolved the principal from the task-local `ClientSessionMiddleware` bound around
    /// this handler and refused the request if it was absent, so this cannot mint owner authority
    /// for an anonymous caller. That the parameter is non-optional is the point: an earlier version
    /// read the task-local here and passed whatever it found, which was `nil` for every
    /// unauthenticated request.
    private static func authority(principal: UUID) -> RegistrationAuthority {
        RegistrationAuthority(creator: .owner(accountID: principal), surface: .http)
    }

    private static func status(for error: TriggerRegistrationError) -> HTTPStatus {
        switch error {
        case .kindNotRegisterable, .channelNotOwned: return .forbidden
        case .channelDisabledInConfig: return .conflict
        case .channelLifecycleUnavailable: return .notImplemented
        case .channelConfigUnreadable: return .internalServerError
        case .notFound: return .notFound
        default: return .badRequest
        }
    }

    // MARK: - Wire shapes

    private static let unknownChannelMessage =
        "Unknown channel (expected one of: \(ChannelId.allCases.map(\.rawValue).joined(separator: ", ")))"

    private static func channel(from req: Request) -> ChannelId? {
        guard let raw = req.parameters.get("channel") else { return nil }
        return ChannelId(rawValue: raw.lowercased())
    }

    private static func json<T: Encodable>(_ value: T) -> Response {
        guard let data = try? JSONEncoder().encode(value) else {
            return APILayerRESTErrorResponse.error(status: .internalServerError, message: "encode_failed")
        }
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}

/// Wire projection of ``ChannelStatusSummary``.
///
/// A separate type rather than making the summary `Codable`: the summary is an internal value that
/// may gain fields for in-process callers, and this is the contract an operator's tooling depends
/// on. Coupling them would make any internal addition a wire change.
struct ChannelAdminStatus: Encodable, Sendable {
    var channel: String
    var transport: String
    var configEnabled: Bool
    var runtimePaused: Bool
    var running: Bool
    var listenerBuilt: Bool
    var state: String
    var lastFatalCode: String?
    var overlayUnreadable: Bool

    init(_ summary: ChannelStatusSummary) {
        channel = summary.channel.rawValue
        transport = summary.transport.rawValue
        configEnabled = summary.configEnabled
        runtimePaused = summary.runtimeDisabled
        running = summary.running
        listenerBuilt = summary.serviceBuilt
        state = summary.state.rawValue
        lastFatalCode = summary.fatalCode
        overlayUnreadable = summary.overlayUnreadable
    }
}

struct ChannelAdminListResponse: Encodable, Sendable {
    var channels: [ChannelAdminStatus]
}

struct ChannelAdminLifecycleResponse: Encodable, Sendable {
    var channel: String
    var paused: Bool
    /// Always true from this surface — it runs in the gateway process, so `reconcile()` applied the
    /// change before the response was written. Reported anyway, because the field is the contract
    /// and the CLI's copy of it is false; a client should not have to know which surface it hit.
    var appliedToRunningProcess: Bool
    var message: String

    init(_ result: ChannelLifecycleResult) {
        channel = result.entry.channel
        paused = result.entry.disabled
        appliedToRunningProcess = result.appliedToRunningProcess
        message = result.summary
    }
}
