import Foundation

enum TriggerSource: String, Codable, Sendable, Equatable {
    case cron
    case webhook
    case channel
    case fileEvent = "file-event"
    case api
    case delegate
}

enum TriggerPayloadFormat: String, Codable, Sendable, Equatable {
    case json
    case text
    case structured
}

enum TriggerInitiatorKind: String, Codable, Sendable, Equatable {
    case user
    case system
    case external
    case agent
}

struct TriggerInitiator: Codable, Sendable, Equatable {
    var kind: TriggerInitiatorKind
    var id: String?
}

struct HarnessTrigger: Codable, Sendable, Equatable {
    var id: String
    var source: TriggerSource
    var sourceMetadata: [String: String]
    var receivedAt: Int64
    var payload: String
    var payloadFormat: TriggerPayloadFormat
    var initiator: TriggerInitiator
    var trust: CommEnvelopeOriginTrust
    var enableTools: Bool
    var enableAgents: Bool
    var routingMode: TriggerRoutingMode

    init(
        id: String,
        source: TriggerSource,
        sourceMetadata: [String: String] = [:],
        receivedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: String,
        payloadFormat: TriggerPayloadFormat = .text,
        initiator: TriggerInitiator,
        trust: CommEnvelopeOriginTrust,
        enableTools: Bool = true,
        enableAgents: Bool = true,
        routingMode: TriggerRoutingMode = .isolated
    ) {
        self.id = id
        self.source = source
        self.sourceMetadata = sourceMetadata
        self.receivedAt = receivedAt
        self.payload = payload
        self.payloadFormat = payloadFormat
        self.initiator = initiator
        self.trust = trust
        self.enableTools = enableTools
        self.enableAgents = enableAgents
        self.routingMode = routingMode
    }
}

enum TriggerRoutingMode: String, Codable, Sendable, Equatable {
    case isolated
    case threaded
    case delegated
}

enum TriggerActivationDecision: String, Codable, Sendable, Equatable {
    case admitted
    case dedupHit = "dedup-hit"
    case rateLimited = "rate-limited"
    case unauthorized
    case overBudget = "over-budget"
}

struct TriggerActivationResult: Sendable, Equatable {
    var decision: TriggerActivationDecision
    var sessionID: UUID?
    var deliverOnlyOutcome: WebhookDeliverOnlyOutcome? = nil
}

enum WebhookDeliverOnlyOutcome: Sendable, Equatable {
    case success
    case deliveryFailed(reason: String)
    case targetMissing
}
