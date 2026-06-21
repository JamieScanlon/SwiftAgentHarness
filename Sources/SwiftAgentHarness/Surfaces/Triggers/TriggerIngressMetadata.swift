import Foundation

enum TriggerIngressMetadata {
    static func enrich(
        _ trigger: HarnessTrigger,
        routingMode: TriggerRoutingMode,
        delegate: TriggerDelegateProfile?,
        deliveryWebhookURL: String? = nil,
        delivery: String? = nil
    ) -> HarnessTrigger {
        var metadata = trigger.sourceMetadata
        if let encoded = TriggerDelegateProfileCodec.encodeToMetadata(delegate) {
            metadata["delegateProfileJSON"] = encoded
        }
        if let deliveryWebhookURL, !deliveryWebhookURL.isEmpty {
            metadata["deliveryWebhookURL"] = deliveryWebhookURL
        }
        if let delivery {
            metadata["delivery"] = delivery
        }
        var updated = trigger
        updated.routingMode = routingMode
        updated.sourceMetadata = metadata
        return updated
    }
}
