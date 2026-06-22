import CryptoKit
import Foundation

public struct WebhookIngressAdapter: Sendable {
    let validationGate: WebhookValidationGate
    let dispatch: TriggerDispatchService
    let directDelivery: WebhookDirectDelivery
    let idempotency: TriggerIdempotencyGate
    let eventsDirectory: URL?

    public func ingest(_ request: WebhookIngressRequest) async throws -> TriggerActivationResult {
        let (route, payload) = try await validationGate.validate(request)
        let rendered = WebhookPromptTemplate.render(template: route.promptTemplate, payload: payload)
        if route.deliverOnly {
            let dedupeKey = request.deliveryID ?? fallbackDedupeKey(routeName: request.routeName, body: request.body)
            if try await !idempotency.claimTrigger(triggerID: dedupeKey) {
                return TriggerActivationResult(decision: .dedupHit, sessionID: nil)
            }
            let extra = WebhookPromptTemplate.renderExtras(route.deliverExtra, payload: payload)
            let outcome = await directDelivery.deliver(route: route, rendered: rendered, extra: extra)
            return TriggerActivationResult(decision: .admitted, sessionID: nil, deliverOnlyOutcome: outcome)
        }
        let deliveryID = request.deliveryID ?? UUID().uuidString
        if let eventsDirectory {
            try FileEventQueueWriter.writeImmediate(
                eventsDirectory: eventsDirectory,
                basename: deliveryID,
                text: rendered,
                trust: FileEventTrustSidecar(
                    trust: route.trust,
                    source: "webhook",
                    routeName: route.name
                )
            )
            return TriggerActivationResult(decision: .admitted, sessionID: nil)
        }
        var sourceMetadata: [String: String] = [
            "routeName": route.name,
            "delivery": route.delivery,
        ]
        TriggerTrustCodec.stampKnownPartyPreambleOverride(
            into: &sourceMetadata,
            enabled: route.includeKnownPartySecurityPreamble ?? true
        )
        let trigger = TriggerIngressMetadata.enrich(
            HarnessTrigger(
                id: deliveryID,
                source: .webhook,
                sourceMetadata: sourceMetadata,
                payload: rendered,
                payloadFormat: .json,
                initiator: TriggerInitiator(kind: .external, id: route.name),
                trust: route.trust,
                routingMode: route.routingMode
            ),
            routingMode: route.routingMode,
            delegate: route.delegate,
            deliveryWebhookURL: route.deliveryWebhookURL
        )
        return try await dispatch.ingest(trigger)
    }

    private func fallbackDedupeKey(routeName: String, body: Data) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "\(routeName):\(digest)"
    }
}
