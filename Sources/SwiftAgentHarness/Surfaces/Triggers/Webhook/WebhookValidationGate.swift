import CryptoKit
import Foundation

struct WebhookValidationGate: Sendable {
    let routeStore: WebhookRouteStore
    let idempotency: TriggerIdempotencyGate
    let rateLimit: TriggerRateLimitGate
    /// Shared ceiling across every runtime-registered route, in requests per the injected gate's
    /// window (60s as wired).
    var selfRegisteredGlobalPerMin: Int = 60

    func validate(_ request: WebhookIngressRequest) async throws -> (route: WebhookRoute, payload: [String: Any]) {
        guard let route = try routeStore.route(named: request.routeName) else {
            throw WebhookValidationFailure.routeNotFound
        }
        guard route.enabled else {
            throw WebhookValidationFailure.routeDisabled
        }
        guard request.body.count <= route.maxBodyBytes else {
            throw WebhookValidationFailure.bodyTooLarge
        }
        guard verifySignature(route: route, request: request) else {
            throw WebhookValidationFailure.invalidSignature
        }
        try WebhookDeliverOnlyValidation.validate(route: route)
        let dedupeKey = request.deliveryID ?? fallbackDedupeKey(routeName: request.routeName, body: request.body)
        if try await idempotency.peekDuplicate(triggerID: dedupeKey) {
            throw WebhookValidationFailure.duplicate
        }
        if await rateLimit.isRateLimited(key: request.routeName, limit: route.rateLimitPerMin) {
            throw WebhookValidationFailure.rateLimited
        }
        // Self-registered routes additionally share one aggressive global bucket: per-route limits
        // alone do not bound an agent that registers many routes.
        if route.source == .dynamic,
           await rateLimit.isRateLimited(
               key: ValidatedWebhookRoute.reservedGlobalBucketName,
               limit: selfRegisteredGlobalPerMin
           ) {
            throw WebhookValidationFailure.rateLimited
        }
        let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? ["__raw__": String(data: request.body, encoding: .utf8) ?? ""]
        return (route, payload)
    }

    private func fallbackDedupeKey(routeName: String, body: Data) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "\(routeName):\(digest)"
    }

    private func verifySignature(route: WebhookRoute, request: WebhookIngressRequest) -> Bool {
        guard !route.secret.isEmpty else { return false }
        let headers = request.headers.mapKeys { $0.lowercased() }
        switch route.signatureScheme {
        case .gitlabToken:
            guard let token = headers["x-gitlab-token"] else { return false }
            return constantTimeEquals(token, route.secret)
        case .githubSHA256:
            guard let sig = headers["x-hub-signature-256"] else { return false }
            let expected = "sha256=" + hmacHex(data: request.body, secret: route.secret)
            return constantTimeEquals(sig, expected)
        case .genericHMAC:
            guard let sig = headers["x-webhook-signature"] else { return false }
            return constantTimeEquals(sig, hmacHex(data: request.body, secret: route.secret))
        }
    }

    private func hmacHex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let da = Data(a.utf8)
        let db = Data(b.utf8)
        guard da.count == db.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< da.count {
            diff |= da[i] ^ db[i]
        }
        return diff == 0
    }
}

private extension Dictionary where Key == String {
    func mapKeys(_ transform: (Key) -> Key) -> [Key: Value] {
        Dictionary(map { (transform($0.key), $0.value) }, uniquingKeysWith: { _, new in new })
    }
}
