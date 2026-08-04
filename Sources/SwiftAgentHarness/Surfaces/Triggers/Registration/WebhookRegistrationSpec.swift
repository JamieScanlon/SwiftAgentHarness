import Foundation

/// What a caller asks for when registering a webhook route.
///
/// As with the schedule spec, identity-derived fields are absent by construction: `trust` is clamped
/// from the authority, `source` is stamped, and the creator is resolved server-side. A route
/// registered this way is `known-party` at most — the payloads it will admit are external content
/// regardless of who registered it.
struct WebhookRegistrationSpec: Sendable, Equatable {
    var name: String
    /// Omit to have one generated. A route with no secret cannot start, so runtime registration and
    /// "secret required" are only compatible if the harness mints it.
    var secret: String?
    var signatureScheme: WebhookSignatureScheme
    var promptTemplate: String
    var delivery: String
    var deliverOnly: Bool
    var deliveryWebhookURL: String?
    var deliverExtra: [String: String]?
    var rateLimitPerMin: Int?
    var maxBodyBytes: Int?
    var routingMode: TriggerRoutingMode?
    var delegate: TriggerDelegateProfile?
    var includeKnownPartySecurityPreamble: Bool?
    var enabled: Bool?

    init(
        name: String,
        secret: String? = nil,
        signatureScheme: WebhookSignatureScheme = .genericHMAC,
        promptTemplate: String = "{__raw__}",
        delivery: String = "agent",
        deliverOnly: Bool = false,
        deliveryWebhookURL: String? = nil,
        deliverExtra: [String: String]? = nil,
        rateLimitPerMin: Int? = nil,
        maxBodyBytes: Int? = nil,
        routingMode: TriggerRoutingMode? = nil,
        delegate: TriggerDelegateProfile? = nil,
        includeKnownPartySecurityPreamble: Bool? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.secret = secret
        self.signatureScheme = signatureScheme
        self.promptTemplate = promptTemplate
        self.delivery = delivery
        self.deliverOnly = deliverOnly
        self.deliveryWebhookURL = deliveryWebhookURL
        self.deliverExtra = deliverExtra
        self.rateLimitPerMin = rateLimitPerMin
        self.maxBodyBytes = maxBodyBytes
        self.routingMode = routingMode
        self.delegate = delegate
        self.includeKnownPartySecurityPreamble = includeKnownPartySecurityPreamble
        self.enabled = enabled
    }

    /// The spec an existing route corresponds to. Update is expressed as read-change-re-register so
    /// a patched template goes back through the scanner.
    init(existing route: WebhookRoute) {
        self.init(
            name: route.name,
            secret: route.secret,
            signatureScheme: route.signatureScheme,
            promptTemplate: route.promptTemplate,
            delivery: route.delivery,
            deliverOnly: route.deliverOnly,
            deliveryWebhookURL: route.deliveryWebhookURL,
            deliverExtra: route.deliverExtra,
            rateLimitPerMin: route.rateLimitPerMin,
            maxBodyBytes: route.maxBodyBytes,
            routingMode: route.routingMode,
            delegate: route.delegate,
            includeKnownPartySecurityPreamble: route.includeKnownPartySecurityPreamble,
            enabled: route.enabled
        )
    }
}

enum WebhookRegistrationError: Error, Equatable {
    case invalidName(String)
    case nameCollidesWithStaticRoute(String)
    case templateScanFailed([String])
    case invalidDeliveryTarget
    case tooManyRoutes(limit: Int)
    /// `subscribe` on a name that already exists. Overwriting a live route's template and delivery
    /// target while reporting "subscribed" is a destructive edit wearing an idempotent-create label.
    case alreadyExists(String)
    /// Config rows are authoritative and are not mutable from any runtime client.
    case staticRouteImmutable(String)
    case notOwned(String)
}

/// A webhook route that has cleared the registration validator.
///
/// Same chokepoint shape as `ValidatedScheduledTask`: private initializer, one factory, and the
/// store's write signature accepts nothing else.
struct ValidatedWebhookRoute: Sendable {
    let route: WebhookRoute
    /// Present only when the validator minted a secret. Shown to the caller once, then never again —
    /// the store holds it, but no read path returns it.
    let generatedSecret: String?

    private init(route: WebhookRoute, generatedSecret: String?) {
        self.route = route
        self.generatedSecret = generatedSecret
    }

    static func validate(
        spec: WebhookRegistrationSpec,
        authority: RegistrationAuthority,
        policy: RegistrationPolicy = .default,
        existing: WebhookRoute? = nil,
        staticRouteNames: Set<String> = [],
        existingRouteCount: Int = 0,
        allowOverwrite: Bool = false,
        now: Date = Date()
    ) throws -> ValidatedWebhookRoute {
        guard policy.allowsRegistration(authority.creator, kind: .webhook) else {
            throw TriggerRegistrationError.kindNotRegisterable(
                kind: .webhook,
                creator: authority.creator.auditLabel
            )
        }
        let name = WebhookRouteNaming.normalize(spec.name)
        guard name != Self.reservedGlobalBucketName else {
            throw TriggerRegistrationError.webhook(.invalidName(spec.name))
        }
        // Route names become URL path segments, so the charset is deliberately narrow. Shared with
        // file-event subscription basenames — the same rule for the same reason. The switch to
        // ``TriggerSlug`` is behaviour-preserving here (`normalize` above already trims the line
        // terminators its `\A`/`\z` anchors guard against); the point is that there is now one
        // definition to fix rather than two to keep in step.
        guard TriggerSlug.isValid(name) else {
            throw TriggerRegistrationError.webhook(.invalidName(spec.name))
        }
        // Config is authoritative over runtime registration: a self-registered route must not be
        // able to shadow a production one by taking its name.
        guard !staticRouteNames.contains(name) else {
            throw TriggerRegistrationError.webhook(.nameCollidesWithStaticRoute(name))
        }
        if let existing {
            guard allowOverwrite else {
                throw TriggerRegistrationError.webhook(.alreadyExists(name))
            }
            guard existing.source == .dynamic else {
                throw TriggerRegistrationError.webhook(.staticRouteImmutable(name))
            }
            // Ownership, not just creator *class*: a main agent in one conversation must not be able
            // to rewrite or retarget a route another owner registered. `createdBy` was stamped and
            // then never read by any authorization path.
            guard Self.isOwned(existing, by: authority) else {
                throw TriggerRegistrationError.webhook(.notOwned(name))
            }
        } else if let limit = policy.maxDynamicWebhookRoutes, existingRouteCount >= limit {
            throw TriggerRegistrationError.webhook(.tooManyRoutes(limit: limit))
        }

        // The prompt template is agent-authorable text that becomes model input on *every* delivery.
        // Schedule prompts have always been scanned; this one was the gap.
        let scan = ProjectInstructionContentScanner.scan(spec.promptTemplate)
        guard scan.isClean else {
            throw TriggerRegistrationError.webhook(.templateScanFailed(scan.matchedThreatIDs))
        }

        var generated: String?
        let secret: String
        // Empty is "keep whatever is stored" — that is what makes `redacted` safe to round-trip.
        if let provided = spec.secret, !provided.isEmpty {
            secret = provided
        } else if let existingSecret = existing?.secret, !existingSecret.isEmpty {
            secret = existingSecret
        } else {
            let minted = Self.generateSecret()
            generated = minted
            secret = minted
        }

        let ceiling = policy.maxTrust(for: authority.creator, kind: .webhook)
        let trust = RegistrationTrustRank.clamp(existing?.trust ?? .knownParty, ceiling: ceiling)

        let route = WebhookRoute(
            name: name,
            secret: secret,
            signatureScheme: spec.signatureScheme,
            promptTemplate: spec.promptTemplate,
            trust: trust,
            delivery: spec.delivery,
            deliverOnly: spec.deliverOnly,
            rateLimitPerMin: spec.rateLimitPerMin ?? existing?.rateLimitPerMin ?? 30,
            maxBodyBytes: spec.maxBodyBytes ?? existing?.maxBodyBytes ?? 1_048_576,
            enabled: spec.enabled ?? existing?.enabled ?? true,
            // Stamped, never taken from the caller. Rows loaded from the dynamic store used to claim
            // `.static`, which quietly inverted the "static wins" collision rule.
            source: .dynamic,
            routingMode: spec.routingMode ?? existing?.routingMode ?? .isolated,
            delegate: spec.delegate ?? existing?.delegate,
            deliveryWebhookURL: spec.deliveryWebhookURL ?? existing?.deliveryWebhookURL,
            deliverExtra: spec.deliverExtra ?? existing?.deliverExtra,
            includeKnownPartySecurityPreamble: spec.includeKnownPartySecurityPreamble
                ?? existing?.includeKnownPartySecurityPreamble,
            createdBy: existing?.createdBy ?? authority.creator,
            createdAtMs: existing?.createdAtMs ?? Int64(now.timeIntervalSince1970 * 1000),
            updatedAtMs: Int64(now.timeIntervalSince1970 * 1000)
        )

        // Deliver-only was previously only checked at ingest, so a misconfigured route was accepted
        // and then failed on every delivery. Check it where the mistake is made.
        do {
            try WebhookDeliverOnlyValidation.validate(route: route)
        } catch {
            throw TriggerRegistrationError.webhook(.invalidDeliveryTarget)
        }

        return ValidatedWebhookRoute(route: route, generatedSecret: generated)
    }

    /// A route with no recorded creator (static config, or a row written before the registration
    /// layer) is owner-managed only; otherwise the owner accounts must match.
    static func isOwned(_ route: WebhookRoute, by authority: RegistrationAuthority) -> Bool {
        switch authority.creator {
        case .installer, .owner:
            return true
        case .agent, .subAgent:
            guard let creator = route.createdBy else { return false }
            return creator.ownerAccountID == authority.creator.ownerAccountID
        }
    }

    /// Flip the pause flag without re-running content validation — the same escape hatch the
    /// schedule path has, and for the same reason: a route whose stored template trips a scanner
    /// rule added *after* registration is exactly the route a user needs to be able to pause.
    static func enabledToggle(of existing: WebhookRoute, enabled: Bool, now: Date = Date()) -> ValidatedWebhookRoute {
        var route = existing
        route.enabled = enabled
        route.updatedAtMs = Int64(now.timeIntervalSince1970 * 1000)
        return ValidatedWebhookRoute(route: route, generatedSecret: nil)
    }

    /// Not registrable: the shared self-registered rate bucket uses this key, and a route holding it
    /// would share a counter with the global ceiling.
    static let reservedGlobalBucketName = "self-registered-webhooks"

    /// 32 random bytes, base64url. Returned to the caller once so they can configure the upstream
    /// service; the harness keeps the only other copy.
    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
