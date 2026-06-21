import Foundation

enum WebhookSignatureScheme: String, Codable, Sendable, Equatable {
    case githubSHA256 = "github-sha256"
    case gitlabToken = "gitlab-token"
    case genericHMAC = "generic-hmac"
}

enum WebhookRouteSource: String, Codable, Sendable, Equatable {
    case `static`
    case dynamic
}

struct WebhookRoute: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var secret: String
    var signatureScheme: WebhookSignatureScheme
    var promptTemplate: String
    var trust: CommEnvelopeOriginTrust
    var delivery: String
    var deliverOnly: Bool
    var rateLimitPerMin: Int
    var maxBodyBytes: Int
    var enabled: Bool
    var source: WebhookRouteSource
    var routingMode: TriggerRoutingMode
    var delegate: TriggerDelegateProfile?
    var deliveryWebhookURL: String?
    var deliverExtra: [String: String]? = nil
    var includeKnownPartySecurityPreamble: Bool? = nil

    var id: String { name }

    init(
        name: String,
        secret: String,
        signatureScheme: WebhookSignatureScheme = .genericHMAC,
        promptTemplate: String = "{__raw__}",
        trust: CommEnvelopeOriginTrust = .knownParty,
        delivery: String = "agent",
        deliverOnly: Bool = false,
        rateLimitPerMin: Int = 30,
        maxBodyBytes: Int = 1_048_576,
        enabled: Bool = true,
        source: WebhookRouteSource = .static,
        routingMode: TriggerRoutingMode = .isolated,
        delegate: TriggerDelegateProfile? = nil,
        deliveryWebhookURL: String? = nil,
        deliverExtra: [String: String]? = nil,
        includeKnownPartySecurityPreamble: Bool? = nil
    ) {
        self.name = name
        self.secret = secret
        self.signatureScheme = signatureScheme
        self.promptTemplate = promptTemplate
        self.trust = trust
        self.delivery = delivery
        self.deliverOnly = deliverOnly
        self.rateLimitPerMin = rateLimitPerMin
        self.maxBodyBytes = maxBodyBytes
        self.enabled = enabled
        self.source = source
        self.routingMode = routingMode
        self.delegate = delegate
        self.deliveryWebhookURL = deliveryWebhookURL
        self.deliverExtra = deliverExtra
        self.includeKnownPartySecurityPreamble = includeKnownPartySecurityPreamble
    }
}

enum WebhookDeliverOnlyValidation {
    static func validate(route: WebhookRoute) throws {
        guard route.deliverOnly else { return }
        if route.delivery == "agent" || route.delivery == "log" {
            throw WebhookValidationFailure.deliverOnlyInvalidTarget
        }
        if let url = route.deliveryWebhookURL, !url.isEmpty { return }
        if ChannelId(rawValue: route.delivery) != nil { return }
        throw WebhookValidationFailure.deliverOnlyInvalidTarget
    }
}

struct WebhookIngressRequest: Sendable {
    var routeName: String
    var body: Data
    var headers: [String: String]
    var deliveryID: String?
}

enum WebhookValidationFailure: Error, Equatable {
    case routeNotFound
    case routeDisabled
    case bodyTooLarge
    case invalidSignature
    case duplicate
    case rateLimited
    case deliverOnlyInvalidTarget
}
