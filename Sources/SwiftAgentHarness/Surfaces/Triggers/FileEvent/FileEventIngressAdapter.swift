import Foundation

struct FileEventIngressAdapter: Sendable {
    func makeTrigger(
        payload: FileEventPayload,
        trust: FileEventTrustSidecar,
        eventURL: URL,
        missed: Bool = false,
        eventsDirectory: URL
    ) -> HarnessTrigger {
        var text = payload.text
        if missed {
            text = "[missed] " + text
        }
        let mtime = (try? eventURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64(Date().timeIntervalSince1970 * 1000)
        let initiatorKind: TriggerInitiatorKind = switch trust.trust {
        case .system: .system
        case .userDirect, .userDeferred: .user
        default: .external
        }
        var metadata: [String: String] = [
            "directory": eventsDirectory.lastPathComponent,
            "filename": eventURL.lastPathComponent,
            "eventType": payload.type.rawValue,
        ]
        if let channelId = payload.channelId { metadata["channelId"] = channelId }
        if let routeName = trust.routeName { metadata["routeName"] = routeName }
        if let source = trust.source { metadata["producerSource"] = source }
        if let conversationID = payload.conversationID { metadata["conversationID"] = conversationID }
        let routingMode: TriggerRoutingMode = payload.conversationID == nil ? .isolated : .threaded
        let triggerID = "file-event:\(eventURL.lastPathComponent):\(mtime)"
        let correlation = TriggerCorrelation.fromPayload(
            rootId: payload.rootId,
            parentTriggerId: payload.parentTriggerId,
            correlationId: payload.correlationId,
            fallbackTriggerID: triggerID
        )
        return HarnessTrigger(
            id: triggerID,
            source: .fileEvent,
            sourceMetadata: metadata,
            receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
            payload: text,
            payloadFormat: .structured,
            initiator: TriggerInitiator(kind: initiatorKind, id: trust.initiatorId ?? trust.routeName),
            trust: trust.trust,
            enableTools: true,
            enableAgents: true,
            routingMode: routingMode,
            correlation: correlation
        )
    }
}
