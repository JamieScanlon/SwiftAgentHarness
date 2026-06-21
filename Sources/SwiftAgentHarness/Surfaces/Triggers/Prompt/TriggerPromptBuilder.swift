import Foundation

struct TriggerPromptBuildResult: Codable, Sendable, Equatable {
    var userMessageBody: String
    var systemReminder: String?
}

struct TriggerPromptBuilder: Sendable {
    func build(trigger: HarnessTrigger) -> TriggerPromptBuildResult {
        let payloadText = channelPayloadText(for: trigger)
        let body: String
        if TriggerTrustCodec.requiresExternalEnvelope(for: trigger.trust) {
            let sourceLabel: ExternalContentSourceLabel = switch trigger.source {
            case .webhook: .webhook
            case .channel: .channelMetadata
            case .fileEvent: .api
            default: .unknown
            }
            body = ExternalContentEnvelope.wrap(
                payloadText,
                options: ExternalContentEnvelopeOptions(
                    source: sourceLabel,
                    from: trigger.sourceMetadata["senderId"] ?? trigger.initiator.id,
                    subject: trigger.sourceMetadata["subject"],
                    includeSecurityPreamble: TriggerTrustCodec.includeSecurityPreamble(
                        for: trigger.trust,
                        knownPartyOverride: TriggerTrustCodec.parseKnownPartyPreambleOverride(
                            from: trigger.sourceMetadata
                        )
                    )
                )
            )
        } else {
            body = payloadText
        }

        let reminder = TriggerTrustCodec.requiresProvenanceReminder(for: trigger.trust)
            ? TriggerProvenanceReminder.build(trigger: trigger)
            : nil

        let metadata = triggerMetadata(for: trigger)
        let receivedAt = TriggerTimestampFormatting.isoString(
            from: Date(timeIntervalSince1970: TimeInterval(trigger.receivedAt) / 1000)
        )
        let fullContent = TriggerContentBuilder.buildFullContent(
            messageBody: body,
            triggerMetadata: metadata,
            serverKeys: ["received_at": receivedAt, "source": trigger.source.rawValue, "trust": trigger.trust.rawValue]
        )
        return TriggerPromptBuildResult(userMessageBody: fullContent, systemReminder: reminder)
    }

    private func triggerMetadata(for trigger: HarnessTrigger) -> [String: String] {
        var meta: [String: String] = ["type": trigger.source.rawValue]
        for (k, v) in trigger.sourceMetadata where k != "conversationID" {
            meta[k] = v
        }
        if trigger.source == .channel,
           trigger.payloadFormat == .structured,
           let channelPayload = decodeChannelPayload(trigger.payload) {
            let paths = channelPayload.attachments.compactMap(\.localPath).joined(separator: ",")
            if !paths.isEmpty {
                meta["attachmentPaths"] = paths
            }
        }
        return meta
    }

    private func channelPayloadText(for trigger: HarnessTrigger) -> String {
        guard trigger.source == .channel, trigger.payloadFormat == .structured,
              let channelPayload = decodeChannelPayload(trigger.payload) else {
            return trigger.payload
        }
        return channelPayload.text
    }

    private func decodeChannelPayload(_ payload: String) -> ChannelTriggerPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChannelTriggerPayload.self, from: data)
    }
}
