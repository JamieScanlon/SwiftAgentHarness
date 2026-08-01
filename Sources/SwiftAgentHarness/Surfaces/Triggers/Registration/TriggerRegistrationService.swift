import Foundation
import Logging

/// The single registration endpoint every client goes through — agent tool, slash command, CLI,
/// HTTP admin, the file-event drop directory, and the installer.
///
/// It owns normalization, validation, the create-time content scan, trust assignment, creator
/// stamping, origin capture, and the registration audit trail. Per-kind stores below it are
/// persistence only; none of them can be written around this type, because the store's create
/// signature accepts only a `Validated*` value whose initializer is private to the validator.
///
/// Deliberately a `struct`, not an actor: the serialization point is the store's read-modify-write
/// lock, and keeping this synchronous lets the non-async composition root and the file-event queue's
/// synchronous sync paths call it without restructuring.
///
/// See `harness-template/surfaces/triggers/self-modification.md`.
struct TriggerRegistrationService: Sendable {
    private let store: ScheduledTaskStore
    private let sessionStore: SessionScopedScheduledTaskStore
    private let webhookRoutes: WebhookRouteStore?
    private let channelState: ChannelRuntimeStateStore?
    /// Where `channels.json` lives. The channel ACL is loaded from here, by this type — never
    /// accepted as a caller argument.
    private let channelConfigURL: URL?
    /// Late-bound applier for channel lifecycle decisions. Late because the listener registry is
    /// built *after* this service (it needs the dispatch chain this service also feeds), so the
    /// dependency can only be closed afterwards — the same pattern `TriggerBudgetNotifierHolder`
    /// uses for the budget notice router.
    private let channelApply: ChannelLifecycleApplierHolder?
    private let tenancy: TenancyPolicySettings
    private let auditLog: TriggerAuditLog
    private let policy: RegistrationPolicy
    private let logger: Logger

    init(
        store: ScheduledTaskStore,
        sessionStore: SessionScopedScheduledTaskStore = SessionScopedScheduledTaskStore(),
        webhookRoutes: WebhookRouteStore? = nil,
        channelState: ChannelRuntimeStateStore? = nil,
        channelConfigURL: URL? = nil,
        channelApply: ChannelLifecycleApplierHolder? = nil,
        tenancy: TenancyPolicySettings = .disabled,
        auditLog: TriggerAuditLog,
        policy: RegistrationPolicy = .default,
        logger: Logger
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.webhookRoutes = webhookRoutes
        self.channelState = channelState
        self.channelConfigURL = channelConfigURL
        self.channelApply = channelApply
        self.tenancy = tenancy
        self.auditLog = auditLog
        self.policy = policy
        self.logger = logger
    }

    // MARK: - Kind-generic entry point

    @discardableResult
    func register(_ spec: TriggerRegistrationSpec, authority: RegistrationAuthority) throws -> TriggerRegistrationID {
        switch spec {
        case .schedule(let scheduleSpec):
            let task = try registerSchedule(scheduleSpec, authority: authority)
            return TriggerRegistrationID(kind: .schedule, id: task.id)
        case .webhook(let webhookSpec):
            let result = try registerWebhook(webhookSpec, authority: authority)
            return TriggerRegistrationID(kind: .webhook, id: result.route.name)
        }
    }

    @discardableResult
    func delete(_ id: TriggerRegistrationID, authority: RegistrationAuthority) throws -> Bool {
        switch id.kind {
        case .schedule:
            return try deleteSchedule(id: id.id, authority: authority)
        case .webhook:
            return try deleteWebhook(name: id.id, authority: authority)
        case .channel, .fileEvent:
            throw TriggerRegistrationError.kindNotRegisterable(
                kind: id.kind,
                creator: authority.creator.auditLabel
            )
        }
    }

    // MARK: - Schedule

    /// Create or update a scheduled task. An update re-runs the full create validation — a patched
    /// prompt goes back through the scanner, a patched schedule back through expression validation.
    @discardableResult
    func registerSchedule(
        _ spec: ScheduleRegistrationSpec,
        authority: RegistrationAuthority
    ) throws -> ScheduledTask {
        var op = "create"
        do {
            // Inside the `do` so a store read failure is audited too — not just write failures.
            let existing = try spec.id.flatMap { try schedule(id: $0) }
            op = existing == nil ? "create" : "update"
            if let existing {
                try assertMutable(existing, authority: authority)
            }
            let validated = try ValidatedScheduledTask.validate(
                spec: spec,
                authority: authority,
                policy: policy,
                existing: existing
            )
            // `durable` finally decides something: a session-scoped row never reaches disk.
            // Re-registering across the boundary moves the row rather than leaving a stale twin.
            let saved: ScheduledTask
            if validated.task.durable {
                sessionStore.delete(id: validated.task.id)
                saved = try store.upsert(validated)
            } else {
                _ = try store.delete(id: validated.task.id)
                saved = sessionStore.upsert(validated)
            }
            recordRegistrationAudit(
                op: op,
                id: saved.id,
                authority: authority,
                trust: saved.trust,
                outcome: "ok",
                admitted: true
            )
            return saved
        } catch {
            // Registration errors and store IO failures both get a row: a disk-full create that
            // leaves no trace is indistinguishable from one that never happened.
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: op,
                id: spec.id ?? "-",
                authority: authority,
                trust: spec.requestedTrust ?? .userDeferred,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    /// Installer create with **write-if-missing** semantics.
    ///
    /// Returns `nil` — without writing — when the user has previously deleted this system entry.
    /// Without this, "the user turned it off" and "the installer turned it back on" fight forever on
    /// every boot, and the user learns they cannot control their own harness.
    @discardableResult
    func installSchedule(_ spec: ScheduleRegistrationSpec) throws -> ScheduledTask? {
        guard let id = spec.id else {
            throw TriggerRegistrationError.validation(.invalidSchedule("installer entries require a stable id"))
        }
        if try store.isTombstoned(id: id) {
            logger.info("trigger_registration_install_skipped id=\(id) reason=user-deleted")
            return nil
        }
        return try registerSchedule(spec, authority: .installer)
    }

    /// Remove an installer-provided entry *without* tombstoning it — used when a feature is disabled
    /// in config rather than deleted by the user, so re-enabling the feature reinstalls cleanly.
    @discardableResult
    func uninstallSchedule(id: String) throws -> Bool {
        let removed = try store.delete(id: id, tombstoneSystemEntry: false)
        if removed {
            recordRegistrationAudit(op: "uninstall", id: id, authority: .installer, trust: .system, outcome: "ok", admitted: true)
        }
        return removed
    }

    /// Gate for *any* state-changing operation on an existing registration — delete, and the
    /// on-demand fire, which is a state change in every way that matters (it spends tokens, it can
    /// be looped, and for a `system` entry it invokes harness-privileged work).
    ///
    /// Registration capability must be symmetric: a creator that may not register a trigger must not
    /// be able to delete or fire one either.
    /// Pure authority check — the caller records the audit row, so a denial is logged exactly once.
    func assertMutable(_ task: ScheduledTask, authority: RegistrationAuthority) throws {
        guard policy.allowsRegistration(authority.creator, kind: .schedule) else {
            throw TriggerRegistrationError.kindNotRegisterable(
                kind: .schedule,
                creator: authority.creator.auditLabel
            )
        }
        if isSystemEntry(task), !policy.allowsMutationOfSystemEntry(authority.creator) {
            throw TriggerRegistrationError.immutableSystemEntry(id: task.id)
        }
    }

    /// Authorize an on-demand fire. The scheduler performs the fire itself; this is the gate in
    /// front of it, so `fire_now` cannot be used to reach an entry the caller may not mutate.
    func assertMayFire(id: String, authority: RegistrationAuthority) throws {
        do {
            guard let task = try schedule(id: id) else {
                throw TriggerRegistrationError.notFound
            }
            try assertMutable(task, authority: authority)
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: "fire_now",
                id: id,
                authority: authority,
                trust: .userDeferred,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    @discardableResult
    func deleteSchedule(id: String, authority: RegistrationAuthority) throws -> Bool {
        do {
            guard let task = try schedule(id: id) else {
                // Log only — a not-found delete is routine (the file-event watcher probes both the
                // periodic and the one-shot id for every removed file) and would otherwise put three
                // audit rows in the log for every unrelated file the user deletes.
                logger.debug("trigger_registration op=delete kind=schedule id=\(id) outcome=not_found")
                return false
            }
            try assertMutable(task, authority: authority)
            let systemEntry = isSystemEntry(task)
            // A human deleting a system entry is the last word: tombstone it so the installer's
            // write-if-missing pass does not resurrect it on the next boot.
            let removedDurable = try store.delete(id: id, tombstoneSystemEntry: systemEntry)
            let removedSession = sessionStore.delete(id: id)
            let removed = removedDurable || removedSession
            recordRegistrationAudit(
                op: "delete",
                id: id,
                authority: authority,
                trust: task.trust,
                outcome: removed ? "ok" : "not_found",
                admitted: removed
            )
            return removed
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: "delete",
                id: id,
                authority: authority,
                trust: .userDeferred,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    /// Apply a partial change to an existing registration.
    ///
    /// Re-runs the full create validation — this is deliberately not a targeted field write, because
    /// an update path that skips the scanner is a second unvalidated create path.
    @discardableResult
    func updateSchedule(
        id: String,
        authority: RegistrationAuthority,
        _ mutate: (inout ScheduleRegistrationSpec) -> Void
    ) throws -> ScheduledTask {
        guard let existing = try schedule(id: id) else {
            recordRegistrationAudit(op: "update", id: id, authority: authority, trust: .userDeferred, outcome: "not_found", admitted: false)
            throw TriggerRegistrationError.notFound
        }
        var spec = ScheduleRegistrationSpec(existing: existing)
        mutate(&spec)
        spec.id = id
        // A cross-conversation `agentTurn` create is approval-gated (`ScheduleCreateApprovalPolicy`).
        // That approval was granted for a *specific* prompt, so rewriting the prompt behind it would
        // launder an unapproved payload into an already-approved sibling target. Refuse outright
        // rather than silently allow; the approval-gated update lands with the phase-3 tool
        // consolidation, where the gate can see the stored row.
        if spec.payloadText != existing.payloadText,
           existing.payloadKind == .agentTurn,
           let target = existing.conversationID,
           let callerConversation = authority.creator.conversationID,
           target != callerConversation.uuidString {
            let error = TriggerRegistrationError.crossConversationPayloadChange(id: id)
            recordRegistrationAudit(op: "update", id: id, authority: authority, trust: existing.trust, outcome: error.code, admitted: false)
            throw error
        }
        // `permanent` is not patchable: it is the on-disk marker of `system` trust and the age-out
        // exemption, and it stays wherever the installer left it.
        spec.permanent = existing.permanent
        return try registerSchedule(spec, authority: authority)
    }

    /// Pause or resume without losing the row, its history, or its next-fire anchor.
    ///
    /// Does not re-run content validation — see ``ValidatedScheduledTask/enabledToggle(of:enabled:now:)``.
    @discardableResult
    func setScheduleEnabled(id: String, enabled: Bool, authority: RegistrationAuthority) throws -> ScheduledTask {
        do {
            guard let existing = try schedule(id: id) else {
                throw TriggerRegistrationError.notFound
            }
            try assertMutable(existing, authority: authority)
            let toggled = ValidatedScheduledTask.enabledToggle(of: existing, enabled: enabled)
            let saved: ScheduledTask
            if toggled.task.durable {
                saved = try store.upsert(toggled)
            } else {
                saved = sessionStore.upsert(toggled)
            }
            recordRegistrationAudit(
                op: enabled ? "resume" : "pause",
                id: id,
                authority: authority,
                trust: saved.trust,
                outcome: "ok",
                admitted: true
            )
            return saved
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: enabled ? "resume" : "pause",
                id: id,
                authority: authority,
                trust: .userDeferred,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    // MARK: - Webhook

    struct WebhookRegistrationResult: Sendable {
        var route: WebhookRoute
        /// Non-nil exactly once, on the create that minted it. Hand it to the user so they can
        /// configure the upstream service; no read path ever returns it again.
        var generatedSecret: String?
    }

    /// `allowOverwrite` is false for `subscribe` and true for `update`: re-subscribing to a live
    /// name used to reset its template and delivery target while reporting success.
    @discardableResult
    func registerWebhook(
        _ spec: WebhookRegistrationSpec,
        authority: RegistrationAuthority,
        allowOverwrite: Bool = false
    ) throws -> WebhookRegistrationResult {
        guard let webhookRoutes else {
            throw TriggerRegistrationError.kindNotRegisterable(kind: .webhook, creator: authority.creator.auditLabel)
        }
        let normalizedName = WebhookRouteNaming.normalize(spec.name)
        var op = "create"
        do {
            let existing = try webhookRoutes.dynamicRouteStore.route(named: normalizedName)
            op = existing == nil ? "create" : "update"
            let validated = try ValidatedWebhookRoute.validate(
                spec: spec,
                authority: authority,
                policy: policy,
                existing: existing,
                staticRouteNames: webhookRoutes.staticRouteNames,
                existingRouteCount: try webhookRoutes.dynamicRouteStore.load().count,
                allowOverwrite: allowOverwrite
            )
            let saved = try webhookRoutes.dynamicRouteStore.upsert(validated)
            recordRegistrationAudit(
                op: op,
                kind: .webhook,
                id: saved.name,
                authority: authority,
                trust: saved.trust,
                outcome: "ok",
                admitted: true
            )
            return WebhookRegistrationResult(route: saved, generatedSecret: validated.generatedSecret)
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: op,
                kind: .webhook,
                id: normalizedName,
                authority: authority,
                trust: .knownParty,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    /// Update is re-validation: a patched prompt template goes back through the scanner.
    @discardableResult
    func updateWebhook(
        name: String,
        authority: RegistrationAuthority,
        _ mutate: (inout WebhookRegistrationSpec) -> Void
    ) throws -> WebhookRegistrationResult {
        guard let webhookRoutes, let existing = try webhookRoutes.dynamicRouteStore.route(named: name) else {
            throw TriggerRegistrationError.notFound
        }
        var spec = WebhookRegistrationSpec(existing: existing)
        mutate(&spec)
        spec.name = existing.name
        return try registerWebhook(spec, authority: authority, allowOverwrite: true)
    }

    @discardableResult
    func setWebhookEnabled(name: String, enabled: Bool, authority: RegistrationAuthority) throws -> WebhookRoute {
        let op = enabled ? "resume" : "pause"
        do {
            guard let webhookRoutes,
                  let existing = try webhookRoutes.dynamicRouteStore.route(named: name) else {
                throw TriggerRegistrationError.notFound
            }
            try assertWebhookMutable(existing, authority: authority)
            let saved = try webhookRoutes.dynamicRouteStore.upsert(
                ValidatedWebhookRoute.enabledToggle(of: existing, enabled: enabled)
            )
            recordRegistrationAudit(op: op, kind: .webhook, id: saved.name, authority: authority, trust: saved.trust, outcome: "ok", admitted: true)
            return saved
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(op: op, kind: .webhook, id: name, authority: authority, trust: .knownParty, outcome: outcome, admitted: false)
            throw error
        }
    }

    /// Authority gate for mutating an existing route. The schedule path has `assertMutable`; this is
    /// its counterpart, and its absence meant any conversation could retarget any route.
    func assertWebhookMutable(_ route: WebhookRoute, authority: RegistrationAuthority) throws {
        guard policy.allowsRegistration(authority.creator, kind: .webhook) else {
            throw TriggerRegistrationError.kindNotRegisterable(kind: .webhook, creator: authority.creator.auditLabel)
        }
        guard route.source == .dynamic else {
            throw TriggerRegistrationError.webhook(.staticRouteImmutable(route.name))
        }
        guard ValidatedWebhookRoute.isOwned(route, by: authority) else {
            throw TriggerRegistrationError.webhook(.notOwned(route.name))
        }
    }

    @discardableResult
    func deleteWebhook(name: String, authority: RegistrationAuthority) throws -> Bool {
        guard let webhookRoutes else {
            throw TriggerRegistrationError.kindNotRegisterable(kind: .webhook, creator: authority.creator.auditLabel)
        }
        do {
            guard let existing = try webhookRoutes.dynamicRouteStore.route(named: name) else {
                logger.debug("trigger_registration op=delete kind=webhook name=\(name) outcome=not_found")
                return false
            }
            try assertWebhookMutable(existing, authority: authority)
            let removed = try webhookRoutes.dynamicRouteStore.delete(named: existing.name)
            recordRegistrationAudit(
                op: "delete",
                kind: .webhook,
                id: name,
                authority: authority,
                trust: existing.trust,
                outcome: removed ? "ok" : "not_found",
                admitted: removed
            )
            return removed
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(op: "delete", kind: .webhook, id: name, authority: authority, trust: .knownParty, outcome: outcome, admitted: false)
            throw error
        }
    }

    /// Owner-scoped and redacted by construction.
    ///
    /// A listing that returned every route in the deployment would let any caller enumerate every
    /// route name, prompt template and delivery target — including ones another tenant registered.
    func listWebhooks(authority: RegistrationAuthority) throws -> [WebhookRoute] {
        guard let webhookRoutes else { return [] }
        return try webhookRoutes.allRoutes()
            .filter { ValidatedWebhookRoute.isOwned($0, by: authority) }
            .map(\.redacted)
    }

    // MARK: - Channel lifecycle

    /// Authority gate for changing a channel's lifecycle state.
    ///
    /// `allowsRegistration(_:kind: .channel)` is owner/installer only, and that verdict is reused
    /// here deliberately: a creator that may not register a channel must not be able to silence one
    /// either. Silencing is the more attacker-interesting direction of the two — a channel that has
    /// been turned off is also the channel that stops reporting.
    ///
    /// `config` is loaded **server-side** by the caller of this method inside this type, never
    /// handed in by the client. A resource's own ACL supplied as an argument is not an ACL: passing
    /// `nil` would skip the ownership comparison entirely, which is the same defect as a field that
    /// is stamped and never read, wearing a different hat.
    ///
    /// Under strict tenancy both ids must be present and equal. Under `.disabled` tenancy a missing
    /// id on either side falls back to creator class alone — the same ladder
    /// `AgentMemoryPathResolver` uses, and what keeps single-tenant deployments (where nothing
    /// carries an account id at all) working.
    private func assertChannelMutable(
        channel: ChannelId,
        config: ChannelListenerConfig?,
        authority: RegistrationAuthority
    ) throws {
        guard policy.allowsRegistration(authority.creator, kind: .channel) else {
            throw TriggerRegistrationError.kindNotRegisterable(
                kind: .channel,
                creator: authority.creator.auditLabel
            )
        }
        if case .installer = authority.creator { return }
        let callerOwner = authority.creator.ownerAccountID
        // Strict tenancy forbids the anonymous local-trust surfaces outright: in a multi-tenant
        // deployment "whoever can reach the data directory" is not a principal.
        if tenancy.requireAuthenticatedOwnerOnMutations, callerOwner == nil {
            throw TriggerRegistrationError.channelNotOwned(channel: channel.rawValue)
        }
        // No account id and non-strict tenancy: the CLI and the file drop, whose credential is
        // filesystem access. Nothing an account id would add. (The HTTP surface cannot reach here
        // with a nil id — it refuses before building the authority.)
        guard let callerOwner else { return }
        // An earlier version additionally required `configOwner` to be present under strict
        // tenancy, which meant a correctly authenticated owner got `channel_not_owned` on every
        // channel, because `owner_account_id` is optional and undocumented. A channel with no
        // recorded owner is unpartitioned, not forbidden.
        guard let configOwner = config?.ownerAccountID else { return }
        guard configOwner == callerOwner else {
            throw TriggerRegistrationError.channelNotOwned(channel: channel.rawValue)
        }
    }

    /// Persist a channel lifecycle decision, apply it to the live process, and audit it.
    ///
    /// Writes only the runtime overlay: `channels.json` is operator config and is never rewritten
    /// from a runtime client, the same rule `staticRouteImmutable` enforces for webhook routes. The
    /// overlay can only hold a permitted channel off — enabling here clears a previous hold, it does
    /// not override an operator's `enabled: false`.
    ///
    /// The apply step is not optional. A `pause` that persists an intent, reports success, and
    /// leaves the channel ingesting until the next restart is the wrong failure for a control whose
    /// entire justification is that silencing needs to take effect *now*. When no reconcile port is
    /// installed the call still succeeds — the overlay is authoritative at next start — but says so
    /// in its result rather than implying the listener stopped.
    @discardableResult
    func setChannelEnabled(
        channel: ChannelId,
        enabled: Bool,
        authority: RegistrationAuthority,
        reason: String? = nil
    ) async throws -> ChannelLifecycleResult {
        let op = enabled ? "resume" : "pause"
        do {
            // Both halves or neither: without the config URL there is no ACL to check against, and
            // a lifecycle mutation that skips the ownership comparison is worse than one that is
            // unavailable.
            guard let channelState, let channelConfigURL else {
                throw TriggerRegistrationError.channelLifecycleUnavailable
            }
            // Loaded here, from disk, under this type's control.
            let loaded = ChannelConfigLoader.loadResult(from: channelConfigURL)
            guard loaded.decodedCleanly else {
                throw TriggerRegistrationError.channelConfigUnreadable(channel: channel.rawValue)
            }
            // A channel absent from `channels.json` is refused in *both* directions. Only the
            // enable branch checked before, so pausing a nonexistent channel returned success and
            // wrote an overlay row for it — while `GET /api/channels/{channel}` answered 404 for the
            // same name, because status reports from config.
            guard let config = loaded.file.config(for: channel) else {
                throw TriggerRegistrationError.notFound
            }
            try assertChannelMutable(channel: channel, config: config, authority: authority)
            // Enable additionally requires config to say yes: the overlay may only attenuate.
            if enabled, !config.enabled {
                throw TriggerRegistrationError.channelDisabledInConfig(channel: channel.rawValue)
            }
            let entry = try channelState.setDisabled(
                channel: channel,
                disabled: !enabled,
                changedBy: authority.creator,
                reason: reason
            )
            var applied = false
            if let channelApply {
                applied = await channelApply.applyChannelState()
            }
            recordRegistrationAudit(
                op: op,
                kind: .channel,
                id: channel.rawValue,
                authority: authority,
                trust: .knownParty,
                outcome: applied ? "ok" : "ok_pending_restart",
                admitted: true
            )
            return ChannelLifecycleResult(entry: entry, appliedToRunningProcess: applied)
        } catch {
            let outcome = (error as? TriggerRegistrationError)?.code ?? "store_error"
            recordRegistrationAudit(
                op: op,
                kind: .channel,
                id: channel.rawValue,
                authority: authority,
                trust: .knownParty,
                outcome: outcome,
                admitted: false
            )
            throw error
        }
    }

    /// The persisted overlay, owner-scoped and redacted.
    ///
    /// Same shape as `listWebhooks(authority:)` and for the same reason: an unfiltered listing would
    /// hand one caller every other actor's conversation, lineage-root and owner-account UUIDs, plus
    /// whatever free text they wrote into `reason`.
    func channelRuntimeState(authority: RegistrationAuthority) throws -> [ChannelRuntimeStateView] {
        guard let channelState else { return [] }
        let callerOwner = authority.creator.ownerAccountID
        // The installer, and an owner surface with no account id at all (single-tenant), see
        // everything. Anyone else sees only rows with no recorded owner or a matching one.
        let unscoped = authority.creator.isInstaller || (!authority.creator.isModelDriven && callerOwner == nil)
        return try channelState.load().values
            .filter { entry in
                if unscoped { return true }
                guard let owner = entry.changedBy?.ownerAccountID else { return true }
                return owner == callerOwner
            }
            .sorted { $0.channel < $1.channel }
            .map {
                ChannelRuntimeStateView(
                    channel: $0.channel,
                    disabled: $0.disabled,
                    updatedAtMs: $0.updatedAtMs,
                    changedByLabel: $0.changedBy?.auditLabel
                )
            }
    }

    // MARK: - Reads

    func listSchedules() throws -> [ScheduledTask] {
        try store.load() + sessionStore.all()
    }

    func schedule(id: String) throws -> ScheduledTask? {
        if let durable = try store.task(id: id) { return durable }
        return sessionStore.task(id: id)
    }

    /// `system` trust, the `permanent` age-out exemption, and installer authorship are three markers
    /// of the same thing; any one of them makes a row installer-owned.
    func isSystemEntry(_ task: ScheduledTask) -> Bool {
        task.permanent || task.trust == .system || task.resolvedCreator.isInstaller
    }

    // MARK: - Audit

    /// Registration rows are audited under the *fire-time* source their kind will produce, so a
    /// query for "everything that ever touched the Slack channel" finds the registration too.
    private static func auditSource(for kind: TriggerKind) -> TriggerSource {
        switch kind {
        case .schedule: return .cron
        case .webhook: return .webhook
        case .channel: return .channel
        case .fileEvent: return .fileEvent
        }
    }

    private func recordRegistrationAudit(
        op: String,
        kind: TriggerKind = .schedule,
        id: String,
        authority: RegistrationAuthority,
        trust: CommEnvelopeOriginTrust,
        outcome: String,
        admitted: Bool
    ) {
        auditLog.record(
            TriggerAuditEntry(
                triggerID: "registration:\(kind.rawValue):\(op):\(id):\(outcome)",
                source: Self.auditSource(for: kind),
                trust: trust,
                receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
                decision: admitted ? .admitted : .unauthorized,
                sessionID: authority.creator.conversationID,
                loggedAt: Date()
            )
        )
        logger.info(
            "trigger_registration op=\(op) kind=\(kind.rawValue) id=\(id) creator=\(authority.creator.auditLabel) surface=\(authority.surface.rawValue) outcome=\(outcome)"
        )
    }
}
