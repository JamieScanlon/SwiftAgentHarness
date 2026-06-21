import Foundation

enum TriggerTrustCodec {
    static func inputTrustRaw(for trust: CommEnvelopeOriginTrust) -> String {
        trust.rawValue
    }

    static func envelopeTag(for trust: CommEnvelopeOriginTrust) -> CommEnvelopeTrustTag {
        CommEnvelopeTrustTag.fromSubAgentTrustRaw(trust.rawValue)
    }

    static func requiresProvenanceReminder(for trust: CommEnvelopeOriginTrust) -> Bool {
        trust != .userDirect
    }

    static func requiresExternalEnvelope(for trust: CommEnvelopeOriginTrust) -> Bool {
        trust == .knownParty || trust == .unknownParty
    }

    static func includeSecurityPreamble(
        for trust: CommEnvelopeOriginTrust,
        knownPartyOverride: Bool? = nil
    ) -> Bool {
        switch trust {
        case .unknownParty: true
        case .knownParty: knownPartyOverride ?? true
        default: false
        }
    }

    static func parseKnownPartyPreambleOverride(from metadata: [String: String]) -> Bool? {
        guard let raw = metadata["includeKnownPartySecurityPreamble"] else { return nil }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    static func stampKnownPartyPreambleOverride(into metadata: inout [String: String], enabled: Bool) {
        guard !enabled else { return }
        metadata["includeKnownPartySecurityPreamble"] = "false"
    }
}
