import Foundation

enum AttachmentProvenancePolicy {
    static func originTrust(from trustRaw: String?) -> CommEnvelopeOriginTrust? {
        guard let sanitized = AttachmentInputTrustCodec.sanitizedInputTrustRaw(trustRaw) else {
            return nil
        }
        if let origin = CommEnvelopeOriginTrust(rawValue: sanitized) {
            return origin
        }
        switch AttachmentInputTrust(rawValue: sanitized) {
        case .directUserEntry:
            return .userDirect
        case .automation, .scripted:
            return .unknownParty
        case nil:
            return nil
        }
    }

    static func requiresExternalEnvelope(trustRaw: String?) -> Bool {
        if let origin = originTrust(from: trustRaw) {
            return TriggerTrustCodec.requiresExternalEnvelope(for: origin)
        }
        guard AttachmentInputTrustCodec.sanitizedInputTrustRaw(trustRaw) != nil else {
            return false
        }
        return AttachmentInputTrustCodec.safePolicyClass(raw: trustRaw) == .lowTrust
    }

    static func includeSecurityPreamble(
        trustRaw: String?,
        metadata: [String: String] = [:]
    ) -> Bool {
        if let origin = originTrust(from: trustRaw) {
            return TriggerTrustCodec.includeSecurityPreamble(
                for: origin,
                knownPartyOverride: TriggerTrustCodec.parseKnownPartyPreambleOverride(from: metadata)
            )
        }
        return AttachmentInputTrustCodec.safePolicyClass(raw: trustRaw) == .lowTrust
    }

    static func externalContentSource(
        descriptor: ConversationAttachmentDescriptor,
        metadata: [String: String] = [:]
    ) -> ExternalContentSourceLabel {
        if metadata["channelOrigin"] != nil {
            return .channelMetadata
        }
        if descriptor.addedBy == .agent {
            return .webFetch
        }
        if let origin = originTrust(from: descriptor.trustRaw) {
            switch origin {
            case .knownParty, .unknownParty:
                return .unknown
            default:
                break
            }
        }
        if AttachmentInputTrustCodec.safePolicyClass(raw: descriptor.trustRaw) == .lowTrust {
            return .unknown
        }
        return .unknown
    }

    static func envelopeOptions(
        descriptor: ConversationAttachmentDescriptor,
        metadata: [String: String] = [:]
    ) -> ExternalContentEnvelopeOptions {
        ExternalContentEnvelopeOptions(
            source: externalContentSource(descriptor: descriptor, metadata: metadata),
            from: sanitizedAttachmentName(descriptor.name),
            subject: metadata["subject"],
            includeSecurityPreamble: includeSecurityPreamble(trustRaw: descriptor.trustRaw, metadata: metadata)
        )
    }

    static func wrapIfRequired(
        descriptor: ConversationAttachmentDescriptor,
        content: String,
        metadata: [String: String] = [:]
    ) -> String {
        guard !ExternalContentEnvelope.isAlreadyWrapped(content) else { return content }
        guard requiresExternalEnvelope(trustRaw: descriptor.trustRaw) else { return content }
        return ExternalContentEnvelope.wrap(
            content,
            options: envelopeOptions(descriptor: descriptor, metadata: metadata)
        )
    }

    static func sanitizedAttachmentName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func defaultTrustRaw(for addedBy: ConversationAttachmentAddedBy) -> String {
        switch addedBy {
        case .user:
            return CommEnvelopeOriginTrust.userDirect.rawValue
        case .agent:
            return CommEnvelopeOriginTrust.unknownParty.rawValue
        }
    }
}
