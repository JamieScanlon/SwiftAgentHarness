import EasyJSON
import Foundation

enum TriggerHostConversationMetadata {
    static let triggerHostKey = "triggerHost"
    static let sessionKeyKey = "triggerSessionKey"
    static let triggerFingerprintKey = "triggerFingerprint"

    static func fingerprintJSON(trigger: HarnessTrigger, sessionKey: String) -> JSON? {
        let payload: [String: JSON] = [
            "id": .string(trigger.id),
            "source": .string(trigger.source.rawValue),
            "trust": .string(trigger.trust.rawValue),
            "sessionKey": .string(sessionKey),
            "sourceMetadata": .object(trigger.sourceMetadata.mapValues { .string($0) }),
        ]
        return .object(payload)
    }

    static func stampHostMetadata(
        existing: JSON?,
        trigger: HarnessTrigger,
        sessionKey: String
    ) -> JSON {
        var object: [String: JSON] = [:]
        if case .object(let existingObject) = existing {
            object = existingObject
        }
        object[triggerHostKey] = .boolean(true)
        object[sessionKeyKey] = .string(sessionKey)
        if let fingerprint = fingerprintJSON(trigger: trigger, sessionKey: sessionKey) {
            object[triggerFingerprintKey] = fingerprint
        }
        return .object(object)
    }

    /// Minimal host marker for isolated trigger sessions created before full trigger context is stamped.
    static func minimalHostMetadata(sessionKey: String) -> JSON {
        .object([
            triggerHostKey: .boolean(true),
            sessionKeyKey: .string(sessionKey),
        ])
    }

    static func isTriggerHost(_ metadata: JSON?) -> Bool {
        guard let metadata, case .object(let object) = metadata else { return false }
        guard case .boolean(let value) = object[triggerHostKey] else { return false }
        return value
    }

    static func isFullyConfiguredTriggerHost(
        metadata: JSON?,
        lineageKind: ConversationLineageKind,
        origin: ConversationOrigin
    ) -> Bool {
        guard isTriggerHost(metadata) else { return false }
        guard lineageKind == .root, origin == .system else { return false }
        guard triggerFromFingerprint(metadata) != nil else { return false }
        return true
    }

    static func sessionKey(from metadata: JSON?) -> String? {
        guard let metadata, case .object(let object) = metadata else { return nil }
        guard case .string(let value) = object[sessionKeyKey] else { return nil }
        return value
    }

    static func triggerFromFingerprint(_ metadata: JSON?) -> HarnessTrigger? {
        guard let metadata, case .object(let object) = metadata else { return nil }
        guard case .object(let fingerprint) = object[triggerFingerprintKey] else { return nil }
        guard case .string(let id) = fingerprint["id"],
              case .string(let sourceRaw) = fingerprint["source"],
              let source = TriggerSource(rawValue: sourceRaw),
              case .string(let trustRaw) = fingerprint["trust"],
              let trust = CommEnvelopeOriginTrust(rawValue: trustRaw)
        else { return nil }
        var sourceMetadata: [String: String] = [:]
        if case .object(let metaObject) = fingerprint["sourceMetadata"] {
            for (key, value) in metaObject {
                if case .string(let stringValue) = value {
                    sourceMetadata[key] = stringValue
                }
            }
        }
        return HarnessTrigger(
            id: id,
            source: source,
            sourceMetadata: sourceMetadata,
            payload: "",
            initiator: TriggerInitiator(kind: .external),
            trust: trust,
            routingMode: .delegated
        )
    }
}
