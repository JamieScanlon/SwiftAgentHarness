import CryptoKit
import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("WebhookIngressAdapter")
struct WebhookIngressAdapterTests {
    actor SharedDedupe: TriggerDedupeChecking {
        private var claimed: Set<String> = []

        func dedupePeek(key: String) async throws -> Bool {
            claimed.contains(key)
        }

        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if claimed.contains(key) { return false }
            claimed.insert(key)
            return true
        }
    }

    final class StubRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var dispatchCount = 0

        func dispatchTriggerMessage(
            conversationID: UUID,
            text: String,
            systemReminder: String?,
            inputTrustRaw: String?,
            resolvedInputTrustClass: TrustPolicyClass?,
            enableTools: Bool,
            enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?,
        originSenderIsOwner: Bool?
    ) async throws {
            dispatchCount += 1
        }
    }

    @Test("direct dispatch with deliveryID is not dropped by double idempotency consume")
    func directDispatchDoesNotSelfDedup() async throws {
        let secret = "secret"
        let body = Data("{\"event\":\"push\"}".utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(
            staticRoutes: [route],
            dynamicStore: tempDynamicStore()
        )
        let dedupe = SharedDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let runtime = StubRuntime()
        let dispatch = makeDispatch(runtime: runtime, dedupe: dedupe)
        let adapter = makeWebhookAdapter(
            gate: gate,
            dispatch: dispatch,
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            eventsDirectory: nil
        )
        let result = try await adapter.ingest(
            WebhookIngressRequest(
                routeName: "github",
                body: body,
                headers: ["X-Webhook-Signature": sig],
                deliveryID: "delivery-123"
            )
        )
        #expect(result.decision == .admitted)
        #expect(runtime.dispatchCount == 1)
    }

    @Test("validation peek rejects duplicate delivery without consuming claim slot")
    func validationPeekRejectsDuplicateWithoutClaiming() async throws {
        let secret = "secret"
        let body = Data("{\"event\":\"push\"}".utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "github", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(
            staticRoutes: [route],
            dynamicStore: tempDynamicStore()
        )
        let dedupe = SharedDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        _ = try await gate.validate(
            WebhookIngressRequest(
                routeName: "github",
                body: body,
                headers: ["X-Webhook-Signature": sig],
                deliveryID: "delivery-dup"
            )
        )
        let idempotency = TriggerIdempotencyGate(dedupe: dedupe)
        #expect(try await idempotency.claimTrigger(triggerID: "delivery-dup"))
        await #expect(throws: WebhookValidationFailure.duplicate) {
            _ = try await gate.validate(
                WebhookIngressRequest(
                    routeName: "github",
                    body: body,
                    headers: ["X-Webhook-Signature": sig],
                    deliveryID: "delivery-dup"
                )
            )
        }
    }

    private func makeWebhookAdapter(
        gate: WebhookValidationGate,
        dispatch: TriggerDispatchService,
        idempotency: TriggerIdempotencyGate,
        eventsDirectory: URL?
    ) -> WebhookIngressAdapter {
        WebhookIngressAdapter(
            validationGate: gate,
            dispatch: dispatch,
            directDelivery: WebhookDirectDelivery(
                channelRegistry: ChannelListenerRegistry.load(
                    dataDirectory: FileManager.default.temporaryDirectory,
                    ingress: ChannelIngressAdapter(dispatch: dispatch),
                    dedupe: ReplayHarnessDedupe(),
                    logger: Logger(label: "test"),
                    enabled: false,
                    configURL: nil
                )
            ),
            idempotency: idempotency,
            eventsDirectory: eventsDirectory
        )
    }

    private func makeDispatch(runtime: StubRuntime, dedupe: SharedDedupe) -> TriggerDispatchService {
        let audit = TriggerAuditLog(logger: Logger(label: "test"))
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: audit
        )
        let router = TriggerSessionRouter(
            sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })
        )
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime
        )
    }

    private func tempDynamicStore() -> WebhookDynamicRouteStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wh-ing-\(UUID().uuidString).json")
        return WebhookDynamicRouteStore(fileURL: url)
    }

    private func hmacHex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
