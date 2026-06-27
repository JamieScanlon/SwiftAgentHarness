import Foundation

enum ChannelTriggerBuilder {
    static func build(
        event: ChannelMessageEvent,
        config: ChannelListenerConfig,
        trust: CommEnvelopeOriginTrust,
        effectiveWasMentioned: Bool,
        burst: ChannelDebounceBurstMetadata?
    ) throws -> HarnessTrigger {
        let replyTo: ChannelReplyTo? = event.replyToMessageId.map {
            ChannelReplyTo(messageId: $0, text: event.replyToText)
        }
        let payload = ChannelTriggerPayload(text: event.text, attachments: event.attachments, replyTo: replyTo)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadJSON = String(data: try encoder.encode(payload), encoding: .utf8) ?? event.text
        let sessionResolution = ChannelSessionGrammar.resolve(event: event, config: config)
        var metadata: [String: String] = [
            "channel": event.channel.rawValue,
            "chatId": event.chatId,
            "senderId": event.senderId,
            "platformMessageId": event.platformMessageId,
            "isDirect": String(event.isDirect),
            "isGroup": String(event.isGroup),
            "wasMentioned": String(effectiveWasMentioned),
            "sessionKeyOverride": sessionResolution.baseConversationKey,
            "baseConversationKey": sessionResolution.baseConversationKey,
        ]
        if !sessionResolution.parentFallbackCandidates.isEmpty {
            metadata["parentFallbackCandidates"] = sessionResolution.parentFallbackCandidates.joined(separator: "|")
        }
        if let threadId = event.threadId { metadata["threadId"] = threadId }
        if let updateId = event.platformUpdateId { metadata["platformUpdateId"] = updateId }
        if let burst {
            metadata["debounceBurstIds"] = burst.messageIds.joined(separator: ",")
            metadata["debounceBurstFirstAt"] = String(burst.firstAt)
            metadata["debounceBurstLastAt"] = String(burst.lastAt)
        }
        TriggerTrustCodec.stampKnownPartyPreambleOverride(
            into: &metadata,
            enabled: config.includeKnownPartySecurityPreamble
        )
        let initiatorKind: TriggerInitiatorKind = event.senderId == config.primaryUser ? .user : .external
        let base = HarnessTrigger(
            id: "\(event.channel.rawValue):\(event.platformMessageId)",
            source: .channel,
            sourceMetadata: metadata,
            receivedAt: event.receivedAt,
            payload: payloadJSON,
            payloadFormat: .structured,
            initiator: TriggerInitiator(kind: initiatorKind, id: event.senderId),
            trust: trust,
            routingMode: config.routingMode
        )
        return TriggerIngressMetadata.enrich(
            base,
            routingMode: config.routingMode,
            delegate: config.delegate
        )
    }
}
