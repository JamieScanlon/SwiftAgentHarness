import CryptoKit
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("WebhookValidationGate")
struct WebhookValidationGateTests {
    @Test("validates HMAC signature")
    func validSignature() async throws {
        let secret = "test-secret"
        let body = Data("{\"ok\":true}".utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: AlwaysAdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let result = try await gate.validate(
            WebhookIngressRequest(
                routeName: "github",
                body: body,
                headers: ["X-Webhook-Signature": sig],
                deliveryID: "d1"
            )
        )
        #expect(result.route.name == "github")
    }

    @Test("rejects invalid signature")
    func invalidSignature() async {
        let route = WebhookRoute(name: "r", secret: "s", signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: AlwaysAdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        await #expect(throws: WebhookValidationFailure.invalidSignature) {
            _ = try await gate.validate(
                WebhookIngressRequest(routeName: "r", body: Data("x".utf8), headers: [:], deliveryID: "d2")
            )
        }
    }

    @Test("case variant duplicate headers do not trap")
    func caseVariantDuplicateHeadersDoNotTrap() async {
        let route = WebhookRoute(name: "r", secret: "s", signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: AlwaysAdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        await #expect(throws: WebhookValidationFailure.invalidSignature) {
            _ = try await gate.validate(
                WebhookIngressRequest(
                    routeName: "r",
                    body: Data("x".utf8),
                    headers: [
                        "X-Webhook-Signature": "bad",
                        "x-webhook-signature": "also-bad",
                    ],
                    deliveryID: "d-case-dup"
                )
            )
        }
    }

    @Test("case variant duplicate headers with valid signature succeed")
    func caseVariantDuplicateHeadersWithValidSignatureSucceed() async throws {
        let secret = "test-secret"
        let body = Data("{\"ok\":true}".utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: AlwaysAdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let result = try await gate.validate(
            WebhookIngressRequest(
                routeName: "github",
                body: body,
                headers: [
                    "X-Webhook-Signature": sig,
                    "x-webhook-signature": sig,
                ],
                deliveryID: "d-both-valid"
            )
        )
        #expect(result.route.name == "github")
    }

    @Test("fallback dedupe key uses stable SHA-256 digest")
    func stableFallbackDedupeKey() async throws {
        let secret = "test-secret"
        let body = Data("{\"stable\":true}".utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let recorder = RecordingDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: recorder),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        _ = try await gate.validate(
            WebhookIngressRequest(routeName: "github", body: body, headers: ["X-Webhook-Signature": sig])
        )
        _ = try await gate.validate(
            WebhookIngressRequest(routeName: "github", body: body, headers: ["X-Webhook-Signature": sig])
        )
        let peekKeys = await recorder.peekKeys
        #expect(peekKeys.count == 2)
        #expect(peekKeys[0] == peekKeys[1])
        #expect(peekKeys[0].hasPrefix("trigger:github:"))
        let digest = String(peekKeys[0].dropFirst("trigger:github:".count))
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit })
    }

    @Test("distinct bodies produce distinct fallback dedupe keys")
    func distinctBodiesDistinctKeys() async throws {
        let secret = "test-secret"
        let bodyA = Data("{\"a\":1}".utf8)
        let bodyB = Data("{\"b\":2}".utf8)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let recorder = RecordingDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: recorder),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let sigA = hmacHex(data: bodyA, secret: secret)
        let sigB = hmacHex(data: bodyB, secret: secret)
        _ = try await gate.validate(
            WebhookIngressRequest(routeName: "github", body: bodyA, headers: ["X-Webhook-Signature": sigA])
        )
        _ = try await gate.validate(
            WebhookIngressRequest(routeName: "github", body: bodyB, headers: ["X-Webhook-Signature": sigB])
        )
        let peekKeys = await recorder.peekKeys
        #expect(peekKeys.count == 2)
        #expect(peekKeys[0] != peekKeys[1])
    }

    private actor RecordingDedupe: TriggerDedupeChecking {
        private(set) var peekKeys: [String] = []
        private(set) var claimKeys: [String] = []
        private var claimed: Set<String> = []

        func dedupePeek(key: String) async throws -> Bool {
            peekKeys.append(key)
            return claimed.contains(key)
        }

        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            claimKeys.append(key)
            if claimed.contains(key) { return false }
            claimed.insert(key)
            return true
        }
    }

    private struct AlwaysAdmitDedupe: TriggerDedupeChecking {
        func dedupePeek(key: String) async throws -> Bool { false }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
    }

    private func tempDynamicStore() -> WebhookDynamicRouteStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wh-\(UUID().uuidString).json")
        return WebhookDynamicRouteStore(fileURL: url)
    }

    private func hmacHex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
