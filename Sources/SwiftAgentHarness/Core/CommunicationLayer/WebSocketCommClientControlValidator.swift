import Foundation

/// Structural validation for inbound harness control frames (`kind: subscribe|unsubscribe|ack|dedupe_check_and_set`) before Codable decode.
/// Matches [`comm-client-control.schema.json`](../../../openapi/schemas/ws/comm-client-control.schema.json).
enum WebSocketCommClientControlValidator {
    /// Returns an English error message suitable for `{"type":"error","message":...}`, or `nil` if valid.
    static func validationError(jsonObject: Any) -> String? {
        guard let obj = jsonObject as? [String: Any] else {
            return "Harness control message must be a JSON object"
        }
        guard let kind = obj["kind"] as? String else {
            return "Harness control message requires kind"
        }

        switch kind {
        case "subscribe":
            let allowedSubscribe = Set([
                "kind", "topic", "since", "sinceMessageSeq", "sinceCheckpointSeq", "resumeToken",
                "conversationId",
            ])
            let keys = Set(obj.keys)
            guard keys.isSubset(of: allowedSubscribe) else {
                let extra = keys.subtracting(allowedSubscribe)
                return "Harness control message has unexpected keys: \(extra.sorted().joined(separator: ", "))"
            }
            guard obj["topic"] is String else {
                return "Subscribe requires string topic"
            }
            if obj["since"] != nil {
                guard jsonInteger(obj["since"]) != nil else {
                    return "since must be an integer when present"
                }
            }
            if obj["sinceMessageSeq"] != nil {
                guard jsonInteger(obj["sinceMessageSeq"]) != nil else {
                    return "sinceMessageSeq must be an integer when present"
                }
            }
            if obj["sinceCheckpointSeq"] != nil {
                guard jsonInteger(obj["sinceCheckpointSeq"]) != nil else {
                    return "sinceCheckpointSeq must be an integer when present"
                }
            }
            if let rt = obj["resumeToken"] {
                guard rt is String else {
                    return "resumeToken must be a string when present"
                }
            }
            if let cid = obj["conversationId"] {
                guard cid is String else {
                    return "conversationId must be a string when present"
                }
            }
            return nil

        case "dedupe_check_and_set":
            let allowed = Set(["kind", "dedupeKey", "dedupeTtlSeconds"])
            let dedupeKeys = Set(obj.keys)
            guard dedupeKeys.isSubset(of: allowed) else {
                let extra = dedupeKeys.subtracting(allowed)
                return "Harness control message has unexpected keys: \(extra.sorted().joined(separator: ", "))"
            }
            guard let key = obj["dedupeKey"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "dedupe_check_and_set requires non-empty dedupeKey string"
            }
            if obj["dedupeTtlSeconds"] != nil {
                guard let ttl = jsonInteger(obj["dedupeTtlSeconds"]), ttl > 0 else {
                    return "dedupeTtlSeconds must be a positive integer when present"
                }
            }
            return nil

        case "unsubscribe":
            let keys = Set(obj.keys)
            guard keys.isSubset(of: ["kind", "topic"]) else {
                let extra = keys.subtracting(["kind", "topic"])
                return "Harness control message has unexpected keys: \(extra.sorted().joined(separator: ", "))"
            }
            guard obj["topic"] is String else {
                return "Unsubscribe requires string topic"
            }
            return nil

        case "ack":
            let keys = Set(obj.keys)
            guard keys.isSubset(of: ["kind", "topic", "upTo"]) else {
                let extra = keys.subtracting(["kind", "topic", "upTo"])
                return "Harness control message has unexpected keys: \(extra.sorted().joined(separator: ", "))"
            }
            guard obj["topic"] is String else {
                return "Ack requires string topic"
            }
            guard jsonInteger(obj["upTo"]) != nil else {
                return "Ack requires integer upTo"
            }
            return nil

        default:
            return "kind must be subscribe, unsubscribe, ack, or dedupe_check_and_set"
        }
    }

    private static func jsonInteger(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double, let i = Int(exactly: d) { return i }
        return nil
    }
}
