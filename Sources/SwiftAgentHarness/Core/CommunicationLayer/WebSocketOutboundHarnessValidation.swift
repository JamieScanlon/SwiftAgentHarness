import Foundation
import Logging

/// Runtime contract checks for outbound websocket harness frames.
enum WebSocketOutboundHarnessValidation {
    private static let envelopeKinds = Set(["snapshot", "event", "lagging"])
    private static let trustClasses = Set(["trusted", "restricted"])
    private static let originTrustValues = Set(["system", "user-direct", "user-deferred", "known-party", "unknown-party"])

    struct ValidationIssue: Error, Sendable, Equatable {
        let detail: String
    }

    static func validationIssueForCommResourceTopicJSONLine(_ json: String) -> ValidationIssue? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ValidationIssue(detail: "line is not JSON object")
        }
        return validationIssueForCommResourceTopicJSONObject(obj)
    }

    static func validationIssueForCommResourceTopicEnvelope<Payload>(
        _ envelope: CommResourceTopicMessage<Payload>
    ) -> ValidationIssue? {
        guard !envelope.topic.isEmpty else {
            return ValidationIssue(detail: "missing/invalid kind/topic/trust tags")
        }
        guard let seq = envelope.seq else {
            return ValidationIssue(detail: "seq must be integer")
        }
        guard seq >= 0 else {
            return ValidationIssue(detail: "seq must be non-negative")
        }
        switch envelope.kind {
        case .lagging:
            if envelope.value != nil {
                return ValidationIssue(detail: "lagging must omit value")
            }
            if envelope.hint == nil {
                return ValidationIssue(detail: "lagging expected to include hint")
            }
        case .snapshot, .event:
            if envelope.value == nil {
                return ValidationIssue(detail: "\(envelope.kind.rawValue) expected value")
            }
        }
        return nil
    }

    static func validationIssueForCommResourceTopicJSONObject(_ obj: [String: Any]) -> ValidationIssue? {
        guard let kind = obj["kind"] as? String, envelopeKinds.contains(kind),
              let topic = obj["topic"] as? String, !topic.isEmpty,
              let trustClass = obj["trustClass"] as? String, trustClasses.contains(trustClass),
              let originTrust = obj["originTrust"] as? String, originTrustValues.contains(originTrust)
        else {
            return ValidationIssue(detail: "missing/invalid kind/topic/trust tags")
        }

        guard let seq = normalizedSeq(obj["seq"]) else { return ValidationIssue(detail: "seq must be integer") }
        guard seq >= 0 else { return ValidationIssue(detail: "seq must be non-negative") }
        switch kind {
        case "lagging":
            if obj["value"] != nil {
                return ValidationIssue(detail: "lagging must omit value")
            }
            if obj["hint"] == nil {
                return ValidationIssue(detail: "lagging expected to include hint")
            }
        case "snapshot", "event":
            if obj["value"] == nil {
                return ValidationIssue(detail: "\(kind) expected value")
            }
            if let m = obj["messageSeq"], normalizedSeq(m) == nil {
                return ValidationIssue(detail: "messageSeq must be integer when present")
            }
            if let c = obj["checkpointSeq"], normalizedSeq(c) == nil {
                return ValidationIssue(detail: "checkpointSeq must be integer when present")
            }
        default:
            break
        }
        let allowed = Set([
            "kind", "topic", "trustClass", "originTrust", "seq", "value", "hint", "messageSeq", "checkpointSeq", "runId", "turnOrdinal", "resumeToken",
        ])
        let extras = Set(obj.keys).subtracting(allowed)
        if !extras.isEmpty {
            return ValidationIssue(detail: "unexpected keys \(extras.sorted())")
        }
        return nil
    }

    static func validationIssueForControlResponsePayload(_ payload: [String: Any]) -> ValidationIssue? {
        guard let kind = payload["kind"] as? String, !kind.isEmpty else {
            return ValidationIssue(detail: "control payload missing kind")
        }
        switch kind {
        case "error":
            guard let message = payload["message"] as? String, !message.isEmpty else {
                return ValidationIssue(detail: "error payload missing message")
            }
            let allowed = Set(["kind", "message", "code"])
            if let code = payload["code"], !(code is String) {
                return ValidationIssue(detail: "error payload code must be string")
            }
            let extras = Set(payload.keys).subtracting(allowed)
            if !extras.isEmpty {
                return ValidationIssue(detail: "error payload unexpected keys \(extras.sorted())")
            }
        case "dedupe_result":
            guard payload["firstSighting"] is Bool else {
                return ValidationIssue(detail: "dedupe_result payload missing firstSighting boolean")
            }
            let allowed = Set(["kind", "firstSighting"])
            let extras = Set(payload.keys).subtracting(allowed)
            if !extras.isEmpty {
                return ValidationIssue(detail: "dedupe_result payload unexpected keys \(extras.sorted())")
            }
        default:
            return ValidationIssue(detail: "unsupported control payload kind \(kind)")
        }
        return nil
    }

    /// Optional soak hook for explicit env-gated diagnostics.
    static func validateCommResourceTopicJSONLineIfEnabled(_ json: String, logger: Logger?) {
        guard ProcessInfo.processInfo.environment["SAH_WS_VALIDATE_OUTBOUND"] == "1" else { return }
        if let issue = validationIssueForCommResourceTopicJSONLine(json) {
            logger?.warning("WS outbound validation: \(issue.detail)")
        }
    }

    private static func normalizedSeq(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double, let i = Int(exactly: d) { return i }
        return nil
    }
}
