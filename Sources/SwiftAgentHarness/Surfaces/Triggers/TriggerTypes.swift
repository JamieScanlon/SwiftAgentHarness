import Foundation

public enum TriggerSource: String, Codable, Sendable, Equatable {
    case cron
    case webhook
    case channel
    case fileEvent = "file-event"
    case api
    case delegate
}

public enum TriggerPayloadFormat: String, Codable, Sendable, Equatable {
    case json
    case text
    case structured
}

public enum TriggerInitiatorKind: String, Codable, Sendable, Equatable {
    case user
    case system
    case external
    case agent
}

public struct TriggerInitiator: Codable, Sendable, Equatable {
    public var kind: TriggerInitiatorKind
    public var id: String?

    public init(kind: TriggerInitiatorKind, id: String? = nil) {
        self.kind = kind
        self.id = id
    }
}

public struct HarnessTrigger: Codable, Sendable, Equatable {
    public var id: String
    public var source: TriggerSource
    public var sourceMetadata: [String: String]
    public var receivedAt: Int64
    public var payload: String
    public var payloadFormat: TriggerPayloadFormat
    public var initiator: TriggerInitiator
    public var trust: CommEnvelopeOriginTrust
    public var enableTools: Bool
    public var enableAgents: Bool
    public var routingMode: TriggerRoutingMode
    public var correlation: TriggerCorrelation?

    public init(
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
        routingMode: TriggerRoutingMode = .isolated,
        correlation: TriggerCorrelation? = nil
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
        self.correlation = correlation
    }
}

public enum TriggerRoutingMode: String, Codable, Sendable, Equatable {
    case isolated
    case threaded
    case delegated
}

public enum TriggerActivationDecision: String, Codable, Sendable, Equatable {
    case admitted
    case dedupHit = "dedup-hit"
    case rateLimited = "rate-limited"
    case unauthorized
    case overBudget = "over-budget"
}

public struct TriggerActivationResult: Sendable, Equatable {
    public var decision: TriggerActivationDecision
    public var sessionID: UUID?
    public var deliverOnlyOutcome: WebhookDeliverOnlyOutcome? = nil

    public init(decision: TriggerActivationDecision, sessionID: UUID?, deliverOnlyOutcome: WebhookDeliverOnlyOutcome? = nil) {
        self.decision = decision
        self.sessionID = sessionID
        self.deliverOnlyOutcome = deliverOnlyOutcome
    }
}

public enum WebhookDeliverOnlyOutcome: Sendable, Equatable {
    case success
    case deliveryFailed(reason: String)
    case targetMissing
}
