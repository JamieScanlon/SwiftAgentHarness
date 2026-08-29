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
    /// Who registered this route. `nil` on static config rows and on rows written before the
    /// registration layer existed. Optional so the synthesized decoder stays back-compatible.
    public var createdBy: RegistrationCreator?
    public var createdAtMs: Int64?
    public var updatedAtMs: Int64?

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
        includeKnownPartySecurityPreamble: Bool? = nil,
        createdBy: RegistrationCreator? = nil,
        createdAtMs: Int64? = nil,
        updatedAtMs: Int64? = nil
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
        self.createdBy = createdBy
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    /// The route as it is safe to show a caller.
    ///
    /// The secret is *cleared*, not masked: an empty secret means "keep the stored one" at the
    /// registration boundary, so a redacted route that finds its way back into an update cannot
    /// install a placeholder as the HMAC key and silently break every upstream delivery. Creator
    /// identity is dropped too — internal conversation and account UUIDs are not the model's
    /// business.
    public var redacted: WebhookRoute {
        var copy = self
        copy.secret = ""
        copy.createdBy = nil
        return copy
    }

    /// Whether this route has a usable secret. A route without one cannot start.
    public var hasSecret: Bool { !secret.isEmpty }
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
