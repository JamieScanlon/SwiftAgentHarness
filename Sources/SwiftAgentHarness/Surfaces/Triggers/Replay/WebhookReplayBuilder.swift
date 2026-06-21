import Foundation

enum WebhookReplayFailure: Error, Equatable {
    case routeNotFound
    case routeDisabled
    case bodyTooLarge
}

struct WebhookReplayBuilder: Sendable {
    let routeStore: WebhookRouteStore

    func build(routeName: String, payload: [String: Any], deliveryID: String? = nil) throws -> HarnessTrigger {
        guard let route = try routeStore.route(named: routeName) else {
            throw WebhookReplayFailure.routeNotFound
        }
        guard route.enabled else {
            throw WebhookReplayFailure.routeDisabled
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard body.count <= route.maxBodyBytes else {
            throw WebhookReplayFailure.bodyTooLarge
        }
        let rendered = WebhookPromptTemplate.render(template: route.promptTemplate, payload: payload)
        let id = deliveryID ?? UUID().uuidString
        let base = HarnessTrigger(
            id: id,
            source: .webhook,
            sourceMetadata: [
                "routeName": route.name,
                "delivery": route.delivery,
            ],
            payload: rendered,
            payloadFormat: .json,
            initiator: TriggerInitiator(kind: .external, id: route.name),
            trust: route.trust,
            routingMode: route.routingMode
        )
        return TriggerIngressMetadata.enrich(
            base,
            routingMode: route.routingMode,
            delegate: route.delegate,
            deliveryWebhookURL: route.deliveryWebhookURL
        )
    }

    func renderedPayload(routeName: String, payload: [String: Any]) throws -> String {
        guard let route = try routeStore.route(named: routeName) else {
            throw WebhookReplayFailure.routeNotFound
        }
        return WebhookPromptTemplate.render(template: route.promptTemplate, payload: payload)
    }
}
