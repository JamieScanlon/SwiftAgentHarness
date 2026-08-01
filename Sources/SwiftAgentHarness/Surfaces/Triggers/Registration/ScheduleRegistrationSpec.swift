import Foundation

/// What a caller asks for when registering a scheduled task.
///
/// Deliberately *not* a `ScheduledTask`: identity, trust, durability, and creator stamping are
/// derived from the ``RegistrationAuthority``, never supplied by the caller. `permanent` is present
/// only so the installer can request it — every other creator is rejected by the validator, which is
/// the schema-level enforcement the trust ceiling depends on.
struct ScheduleRegistrationSpec: Sendable, Equatable {
    /// Omit to mint a fresh id; supply to update an existing row (update re-runs full validation).
    var id: String?
    var schedule: ScheduledTaskSchedule
    var payloadKind: ScheduledTaskPayloadKind
    var payloadText: String
    var delivery: ScheduledTaskDelivery
    var deliveryWebhookURL: String?
    var recurring: Bool
    var conversationID: String?
    var title: String?
    /// `nil` means "infer": isolated when there is no target conversation, threaded when there is.
    /// An explicit `.isolated` is honored literally and clears the target — that distinction is the
    /// reason this is optional rather than defaulted.
    var routingMode: TriggerRoutingMode?
    var delegate: TriggerDelegateProfile?
    var correlation: TriggerCorrelation?
    /// Clamped down to the creator's ceiling; never clamped up.
    var requestedTrust: CommEnvelopeOriginTrust?
    /// Installer-only. Any other creator requesting this is rejected.
    var permanent: Bool
    /// `nil` defers to the creator's default (session-scoped for model-driven registrations).
    var durable: Bool?
    /// `nil` keeps an existing row's pause state, or starts a new row enabled.
    var enabled: Bool?
    /// IANA identifier for `cron` wall-clock evaluation, e.g. `Europe/Berlin`.
    ///
    /// `nil` on a create means "the zone this process is in", which the validator resolves and
    /// stamps rather than leaving implicit — a task that inherits whatever host it later runs on is
    /// how "every morning at 9" becomes 2am after a deploy.
    var timezone: String?

    init(
        id: String? = nil,
        schedule: ScheduledTaskSchedule,
        payloadKind: ScheduledTaskPayloadKind,
        payloadText: String,
        delivery: ScheduledTaskDelivery = .none,
        deliveryWebhookURL: String? = nil,
        recurring: Bool,
        conversationID: String? = nil,
        title: String? = nil,
        routingMode: TriggerRoutingMode? = nil,
        delegate: TriggerDelegateProfile? = nil,
        correlation: TriggerCorrelation? = nil,
        requestedTrust: CommEnvelopeOriginTrust? = nil,
        permanent: Bool = false,
        durable: Bool? = nil,
        enabled: Bool? = nil,
        timezone: String? = nil
    ) {
        self.id = id
        self.schedule = schedule
        self.payloadKind = payloadKind
        self.payloadText = payloadText
        self.delivery = delivery
        self.deliveryWebhookURL = deliveryWebhookURL
        self.recurring = recurring
        self.conversationID = conversationID
        self.title = title
        self.routingMode = routingMode
        self.delegate = delegate
        self.correlation = correlation
        self.requestedTrust = requestedTrust
        self.permanent = permanent
        self.durable = durable
        self.enabled = enabled
        self.timezone = timezone
    }

    /// The spec an existing row corresponds to.
    ///
    /// Update is expressed as "read the row, change fields, re-register", so a patched prompt goes
    /// back through the scanner and a patched schedule back through expression validation. An update
    /// path that skips create-time validation is just a second unvalidated create path.
    init(existing task: ScheduledTask) {
        self.init(
            id: task.id,
            schedule: task.schedule,
            payloadKind: task.payloadKind,
            payloadText: task.payloadText,
            delivery: task.delivery,
            deliveryWebhookURL: task.deliveryWebhookURL,
            recurring: task.recurring,
            conversationID: task.conversationID,
            title: task.title,
            // Re-infer rather than restate: a legacy row stored `.isolated` while behaving as
            // threaded, so echoing the stored value back would silently reroute it on update.
            routingMode: task.routingMode == .delegated ? .delegated : nil,
            delegate: task.delegate,
            correlation: task.correlation,
            requestedTrust: task.trust,
            permanent: task.permanent,
            durable: task.durable,
            enabled: task.enabled,
            timezone: task.timezone
        )
    }
}

/// A scheduled task that has cleared the registration validator.
///
/// This is the chokepoint. `ScheduledTaskStore.upsert` accepts nothing else, and the only way to
/// obtain one is ``validate(spec:authority:policy:existing:now:)`` — which runs schedule validation,
/// the create-time content scan, the `permanent` gate, trust clamping, and creator stamping. A
/// caller cannot reach the store around the validator, because the type it would need to pass has no
/// accessible initializer.
///
/// This is `harness-template/surfaces/triggers/self-modification.md` §"the scanner must run inside
/// the store's create path, not in the agent tool's wrapper", expressed as a type rule rather than a
/// convention.
struct ValidatedScheduledTask: Sendable {
    let task: ScheduledTask

    private init(task: ScheduledTask) {
        self.task = task
    }

    /// Flip the pause flag on a row that already cleared validation.
    ///
    /// Deliberately *not* routed through ``validate``: a pause changes no field validation covers,
    /// and re-running the scanner would mean a row with a stale prompt or a sub-second interval
    /// cannot be paused — i.e. exactly the misbehaving rows a user most needs to stop.
    static func enabledToggle(of existing: ScheduledTask, enabled: Bool, now: Date = Date()) -> ValidatedScheduledTask {
        var task = existing
        task.enabled = enabled
        task.updatedAt = Int64(now.timeIntervalSince1970 * 1000)
        return ValidatedScheduledTask(task: task)
    }

    static func validate(
        spec: ScheduleRegistrationSpec,
        authority: RegistrationAuthority,
        policy: RegistrationPolicy = .default,
        existing: ScheduledTask? = nil,
        now: Date = Date()
    ) throws -> ValidatedScheduledTask {
        guard policy.allowsRegistration(authority.creator, kind: .schedule) else {
            throw TriggerRegistrationError.kindNotRegisterable(
                kind: .schedule,
                creator: authority.creator.auditLabel
            )
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Resolve the zone before the schedule is built.
        //
        // An unrecognised identifier is refused rather than defaulted. Defaulting produces a task
        // that runs — just at the wrong hour, silently, forever; the registration failure is the
        // only version of this a user can see and fix. Only `cron` has a wall-clock to interpret:
        // `at` carries its own offset in the ISO-8601 string and `every` is a pure duration, so
        // neither is stamped.
        let resolvedTimezone: String?
        if spec.schedule.kind != .cron {
            // Nothing to interpret, so nothing to validate. Without this an `at` one-shot carrying a
            // typo'd identifier — which used to register fine, because the field was decoded and
            // dropped — would start being refused for a field that has no effect on it.
            resolvedTimezone = nil
        } else if let requested = spec.timezone, !requested.isEmpty {
            guard TimeZone(identifier: requested) != nil else {
                throw TriggerRegistrationError.validation(.unknownTimezone(requested))
            }
            resolvedTimezone = requested
        } else if let existing {
            // An update keeps the row's zone. Re-deriving it from the updating caller would move an
            // existing schedule the first time it is edited from a host in another zone — the same
            // reasoning that makes attribution and origin create-time properties below.
            resolvedTimezone = existing.timezone
        } else {
            resolvedTimezone = TimeZone.current.identifier
        }

        // Attribution, trust and origin are **create-time** properties. An update re-validates
        // content; it does not re-author the row. Deriving them from the updating authority would
        // let a pause issued from another conversation re-attribute the task (changing who can see
        // it), demote an installer row's trust, or overwrite the channel a reminder answers into.
        let creator = existing?.resolvedCreator ?? authority.creator
        let trust: CommEnvelopeOriginTrust
        if let existing {
            trust = existing.trust
        } else {
            let ceiling = policy.maxTrust(for: authority.creator, kind: .schedule)
            trust = RegistrationTrustRank.clamp(spec.requestedTrust ?? .userDeferred, ceiling: ceiling)
        }

        // Resolve routing once, here, so the stored value is authoritative and the trigger builder
        // can honor it instead of recomputing (and discarding) the caller's choice at fire time.
        let routingMode: TriggerRoutingMode
        let targetConversationID: String?
        switch spec.routingMode {
        case .delegated:
            routingMode = .delegated
            targetConversationID = spec.conversationID
        case .isolated:
            // Explicit isolation means a fresh session; keeping a target would contradict it.
            routingMode = .isolated
            targetConversationID = nil
        case .threaded:
            guard let target = spec.conversationID, !target.isEmpty else {
                throw TriggerRegistrationError.validation(
                    .invalidSchedule("threaded routing requires a target conversationID")
                )
            }
            routingMode = .threaded
            targetConversationID = target
        case .none:
            targetConversationID = spec.conversationID
            routingMode = targetConversationID == nil ? .isolated : .threaded
        }

        let task = ScheduledTask(
            id: spec.id ?? UUID().uuidString,
            // An update preserves the original anchor: next-fire is computed from
            // `lastFiredAt ?? createdAt`, so resetting `createdAt` would silently reschedule.
            createdAt: existing?.createdAt ?? nowMs,
            lastFiredAt: existing?.lastFiredAt,
            schedule: spec.schedule,
            payloadKind: spec.payloadKind,
            payloadText: spec.payloadText,
            delivery: spec.delivery,
            deliveryWebhookURL: spec.deliveryWebhookURL,
            recurring: spec.recurring,
            permanent: spec.permanent,
            durable: spec.durable ?? existing?.durable ?? policy.defaultDurable(for: authority.creator),
            trust: trust,
            conversationID: targetConversationID,
            ownerAccountID: creator.ownerAccountID,
            createdByConversationID: creator.conversationID,
            title: spec.title,
            routingMode: routingMode,
            delegate: spec.delegate,
            correlation: spec.correlation,
            createdBy: creator,
            updatedAt: nowMs,
            origin: (existing?.origin ?? authority.origin)?.normalized,
            enabled: spec.enabled ?? existing?.enabled ?? true,
            timezone: resolvedTimezone
        )

        switch ScheduledTaskCreateScanner.validateCreate(
            task: task,
            allowPermanent: policy.allowsPermanent(authority.creator)
        ) {
        case .failure(let error):
            throw TriggerRegistrationError.validation(error)
        case .success:
            return ValidatedScheduledTask(task: task)
        }
    }
}
