import Foundation

public enum WebhookSignatureScheme: String, Codable, Sendable, Equatable {
    case githubSHA256 = "github-sha256"
    case gitlabToken = "gitlab-token"
    case genericHMAC = "generic-hmac"
}

public enum WebhookRouteSource: String, Codable, Sendable, Equatable {
    case `static`
    case dynamic
}

public struct WebhookRoute: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var secret: String
    public var signatureScheme: WebhookSignatureScheme
    public var promptTemplate: String
    public var trust: CommEnvelopeOriginTrust
    public var delivery: String
    public var deliverOnly: Bool
    public var rateLimitPerMin: Int
    public var maxBodyBytes: Int
    public var enabled: Bool
    public var source: WebhookRouteSource
    public var routingMode: TriggerRoutingMode
    public var delegate: TriggerDelegateProfile?
    public var deliveryWebhookURL: String?
    public var deliverExtra: [String: String]? = nil
    public var includeKnownPartySecurityPreamble: Bool? = nil

    public var id: String { name }

    public init(
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

public struct WebhookIngressRequest: Sendable {
    public var routeName: String
    public var body: Data
    public var headers: [String: String]
    public var deliveryID: String?

    public init(routeName: String, body: Data, headers: [String: String], deliveryID: String? = nil) {
        self.routeName = routeName
        self.body = body
        self.headers = headers
        self.deliveryID = deliveryID
    }
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
