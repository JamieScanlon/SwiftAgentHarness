import Foundation

enum ScheduledTaskScheduleKind: String, Codable, Sendable, Equatable {
    case at
    case every
    case cron
}

enum ScheduledTaskPayloadKind: String, Codable, Sendable, Equatable {
    case systemEvent
    case agentTurn
}

enum ScheduledTaskDelivery: String, Codable, Sendable, Equatable {
    case none
    case announce
    case webhook
}

struct ScheduledTaskSchedule: Codable, Sendable, Equatable {
    var kind: ScheduledTaskScheduleKind
    var at: String?
    var intervalMs: Int64?
    var expr: String?
}

struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var createdAt: Int64
    var lastFiredAt: Int64?
    var schedule: ScheduledTaskSchedule
    var payloadKind: ScheduledTaskPayloadKind
    var payloadText: String
    var delivery: ScheduledTaskDelivery
    var deliveryWebhookURL: String?
    var recurring: Bool
    var permanent: Bool
    var durable: Bool
    var trust: CommEnvelopeOriginTrust
    var conversationID: String?
    var ownerAccountID: UUID?
    var createdByConversationID: UUID?
    var title: String?
    var routingMode: TriggerRoutingMode
    var delegate: TriggerDelegateProfile?
    var correlation: TriggerCorrelation?
    /// Who registered this task. Canonical attribution; `ownerAccountID` and
    /// `createdByConversationID` are mirrors kept in sync by the registration validator and are
    /// retained for the existing owner/lineage access checks.
    ///
    /// `nil` on rows written before the registration layer existed — see ``resolvedCreator``.
    var createdBy: RegistrationCreator?
    var updatedAt: Int64?
    /// Pause knob. A disabled task keeps its row, its history and its anchor — the scheduler simply
    /// skips it. Pausing is what a user reaches for when a trigger misbehaves and they do not want
    /// to lose it.
    var enabled: Bool
    /// Where a fire should announce back to, captured at create time. See ``TriggerOriginRef``.
    var origin: TriggerOriginRef?
    /// IANA identifier the `cron` schedule's wall-clock is evaluated in, e.g. `America/Los_Angeles`.
    ///
    /// Stamped at registration from the caller's zone when not supplied, so a task created on a
    /// laptop keeps firing at the human's 9am after the service is deployed to a UTC host. `nil` is
    /// a row written before this field existed and keeps the old behaviour — the process zone —
    /// because reinterpreting those rows as UTC would move every existing schedule by the
    /// deployment's offset without anyone asking.
    ///
    /// Only meaningful for `cron`. `at` carries its own offset in the ISO-8601 string and `every` is
    /// a pure duration, so neither has a wall-clock to interpret.
    var timezone: String?

    /// Resolved zone for schedule evaluation, or `nil` for the process zone.
    ///
    /// An identifier that no longer resolves — a tzdata rename, or a row hand-edited on disk —
    /// degrades to the process zone with the same reasoning as ``resolvedCreator``: the alternative
    /// is a task that silently stops firing.
    var resolvedTimeZone: TimeZone? {
        guard let timezone else { return nil }
        return TimeZone(identifier: timezone)
    }

    /// Best-effort creator for legacy rows: a pre-registration-layer row with a creating
    /// conversation was written by the agent tool path; one without was written by the installer or
    /// a local sync, both of which are owner-level.
    var resolvedCreator: RegistrationCreator {
        if let createdBy { return createdBy }
        if permanent || trust == .system { return .installer }
        if let conversation = createdByConversationID {
            return .agent(conversationID: conversation, ownerAccountID: ownerAccountID)
        }
        return .owner(accountID: ownerAccountID)
    }

    init(
        id: String = UUID().uuidString,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        lastFiredAt: Int64? = nil,
        schedule: ScheduledTaskSchedule,
        payloadKind: ScheduledTaskPayloadKind,
        payloadText: String,
        delivery: ScheduledTaskDelivery = .none,
        deliveryWebhookURL: String? = nil,
        recurring: Bool,
        permanent: Bool = false,
        durable: Bool = true,
        trust: CommEnvelopeOriginTrust = .userDeferred,
        conversationID: String? = nil,
        ownerAccountID: UUID? = nil,
        createdByConversationID: UUID? = nil,
        title: String? = nil,
        routingMode: TriggerRoutingMode = .isolated,
        delegate: TriggerDelegateProfile? = nil,
        correlation: TriggerCorrelation? = nil,
        createdBy: RegistrationCreator? = nil,
        updatedAt: Int64? = nil,
        origin: TriggerOriginRef? = nil,
        enabled: Bool = true,
        timezone: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
        self.schedule = schedule
        self.payloadKind = payloadKind
        self.payloadText = payloadText
        self.delivery = delivery
        self.deliveryWebhookURL = deliveryWebhookURL
        self.recurring = recurring
        self.permanent = permanent
        self.durable = durable
        self.trust = trust
        self.conversationID = conversationID
        self.ownerAccountID = ownerAccountID
        self.createdByConversationID = createdByConversationID
        self.title = title
        self.routingMode = routingMode
        self.delegate = delegate
        self.correlation = correlation
        self.createdBy = createdBy
        self.updatedAt = updatedAt
        self.origin = origin
        self.enabled = enabled
        self.timezone = timezone
    }

    /// Hand-written so that a task file written by an older build still decodes: every field is
    /// tolerated as absent and falls back to the same default the memberwise initializer uses.
    /// Rows that are malformed beyond that are dropped individually by the store's row wrapper, so
    /// one bad row never fails the whole schedule file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        self.lastFiredAt = try container.decodeIfPresent(Int64.self, forKey: .lastFiredAt)
        self.schedule = try container.decode(ScheduledTaskSchedule.self, forKey: .schedule)
        // Enum-valued fields use `try?`: a *present but unrecognized* raw value throws rather than
        // returning nil, so a row written by a newer build with a new case would otherwise be
        // dropped entirely (and then erased by the next write). Degrade to the default instead.
        self.payloadKind = (try? container.decodeIfPresent(ScheduledTaskPayloadKind.self, forKey: .payloadKind)) ?? .agentTurn
        self.payloadText = try container.decodeIfPresent(String.self, forKey: .payloadText) ?? ""
        self.delivery = (try? container.decodeIfPresent(ScheduledTaskDelivery.self, forKey: .delivery)) ?? .none
        self.deliveryWebhookURL = try container.decodeIfPresent(String.self, forKey: .deliveryWebhookURL)
        self.recurring = try container.decodeIfPresent(Bool.self, forKey: .recurring) ?? false
        self.permanent = try container.decodeIfPresent(Bool.self, forKey: .permanent) ?? false
        self.durable = try container.decodeIfPresent(Bool.self, forKey: .durable) ?? true
        self.trust = (try? container.decodeIfPresent(CommEnvelopeOriginTrust.self, forKey: .trust)) ?? .userDeferred
        self.conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        self.ownerAccountID = try container.decodeIfPresent(UUID.self, forKey: .ownerAccountID)
        self.createdByConversationID = try container.decodeIfPresent(UUID.self, forKey: .createdByConversationID)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.routingMode = (try? container.decodeIfPresent(TriggerRoutingMode.self, forKey: .routingMode)) ?? .isolated
        self.delegate = try? container.decodeIfPresent(TriggerDelegateProfile.self, forKey: .delegate)
        self.correlation = try? container.decodeIfPresent(TriggerCorrelation.self, forKey: .correlation)
        // `try?` rather than `try`: a creator case written by a newer build must degrade to
        // "unattributed" (see `resolvedCreator`) instead of failing the whole row.
        self.createdBy = try? container.decodeIfPresent(RegistrationCreator.self, forKey: .createdBy)
        self.updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt)
        self.origin = try? container.decodeIfPresent(TriggerOriginRef.self, forKey: .origin)
        // Absent on rows written before the pause knob existed — those were all running.
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    }
}
