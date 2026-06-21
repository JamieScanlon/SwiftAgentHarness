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
    var title: String?
    var routingMode: TriggerRoutingMode
    var delegate: TriggerDelegateProfile?

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
        title: String? = nil,
        routingMode: TriggerRoutingMode = .isolated,
        delegate: TriggerDelegateProfile? = nil
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
        self.title = title
        self.routingMode = routingMode
        self.delegate = delegate
    }
}
