import CryptoKit
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("TriggerWebhookRouteRegistrar")
struct TriggerWebhookRouteRegistrarTests {
    @Test("case variant duplicate headers return unauthorized without trapping")
    func caseVariantDuplicateHeadersReturnUnauthorized() async throws {
        let secret = "route-secret"
        let route = WebhookRoute(name: "test-route", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(
            staticRoutes: [route],
            dynamicStore: tempDynamicStore()
        )
        let dedupe = RegistrarTestDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: dedupe),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: RegistrarStubRuntime()
        )
        let adapter = WebhookIngressAdapter(
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
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            eventsDirectory: nil
        )
        let registrar = TriggerWebhookRouteRegistrar(
            routeStore: store,
            adapter: adapter,
            logger: Logger(label: "test")
        )

        try await withApp { app in
            registrar.register(on: app)
            try await app.testing().test(.POST, "webhook/test-route", beforeRequest: { req in
                req.headers.add(name: "X-Webhook-Signature", value: "bad")
                req.headers.add(name: "x-webhook-signature", value: "also-bad")
                req.body = .init(string: #"{"event":"push"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("last case variant signature header wins during ingress")
    func lastCaseVariantSignatureHeaderWins() async throws {
        let secret = "route-secret"
        let body = Data(#"{"event":"push"}"#.utf8)
        let sig = hmacHex(data: body, secret: secret)
        let route = WebhookRoute(name: "test-route", secret: secret, signatureScheme: .genericHMAC)
        let store = WebhookRouteStore(
            staticRoutes: [route],
            dynamicStore: tempDynamicStore()
        )
        let dedupe = RegistrarTestDedupe()
        let gate = WebhookValidationGate(
            routeStore: store,
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
        )
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: dedupe),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: RegistrarStubRuntime()
        )
        let adapter = WebhookIngressAdapter(
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
            idempotency: TriggerIdempotencyGate(dedupe: dedupe),
            eventsDirectory: nil
        )
        let registrar = TriggerWebhookRouteRegistrar(
            routeStore: store,
            adapter: adapter,
            logger: Logger(label: "test")
        )

        try await withApp { app in
            registrar.register(on: app)
            try await app.testing().test(.POST, "webhook/test-route", beforeRequest: { req in
                req.headers.add(name: "X-Webhook-Signature", value: "wrong")
                req.headers.add(name: "x-webhook-signature", value: sig)
                req.body = .init(data: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    private func tempDynamicStore() -> WebhookDynamicRouteStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wh-reg-\(UUID().uuidString).json")
        return WebhookDynamicRouteStore(fileURL: url)
    }

    private func hmacHex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

private struct RegistrarTestDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}

private final class RegistrarStubRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {}
}
