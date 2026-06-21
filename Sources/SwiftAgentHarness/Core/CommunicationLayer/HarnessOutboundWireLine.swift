import Foundation
import Logging

/// Pre-encoded harness topic frame with routing metadata carried alongside the wire JSON.
public struct HarnessOutboundWireLine: Sendable, Equatable {
    public let json: String
    public let kind: CommServerMessageKind
    public let topic: String
    public let seq: Int

    public init(json: String, kind: CommServerMessageKind, topic: String, seq: Int) {
        self.json = json
        self.kind = kind
        self.topic = topic
        self.seq = seq
    }

    /// Validates a typed envelope, encodes once, and returns a wire line for the outbound hot path.
    static func make<Payload: Codable & Sendable>(
        from envelope: CommResourceTopicMessage<Payload>
    ) -> Result<HarnessOutboundWireLine, WebSocketOutboundHarnessValidation.ValidationIssue> {
        if let issue = WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicEnvelope(envelope) {
            return .failure(issue)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope),
              let json = String(data: data, encoding: .utf8),
              let seq = envelope.seq
        else {
            return .failure(.init(detail: "encode failed"))
        }
        return .success(HarnessOutboundWireLine(json: json, kind: envelope.kind, topic: envelope.topic, seq: seq))
    }

    static func makeOrLog<Payload: Codable & Sendable>(
        from envelope: CommResourceTopicMessage<Payload>,
        hubLabel: String,
        logger: Logger?
    ) -> HarnessOutboundWireLine? {
        switch make(from: envelope) {
        case .success(let line):
            return line
        case .failure(let issue):
            logger?.warning("\(hubLabel) outbound schema violation: \(issue.detail)")
            return nil
        }
    }

    /// Parses routing metadata once from stored JSON (replay paths). Validates schema once at the replay boundary.
    static func makeValidatedReplay(json: String, hubLabel: String, logger: Logger?) -> HarnessOutboundWireLine? {
        if let issue = WebSocketOutboundHarnessValidation.validationIssueForCommResourceTopicJSONLine(json) {
            logger?.warning("\(hubLabel) replay schema violation dropped: \(issue.detail)")
            return nil
        }
        return make(json: json)
    }

    /// Parses routing metadata once from stored JSON (replay paths). Skips full schema validation.
    static func make(json: String) -> HarnessOutboundWireLine? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = obj["kind"] as? String,
              let kind = CommServerMessageKind(rawValue: kindRaw),
              let topic = obj["topic"] as? String,
              let seq = normalizedSeq(obj["seq"])
        else {
            return nil
        }
        return HarnessOutboundWireLine(json: json, kind: kind, topic: topic, seq: seq)
    }

    private static func normalizedSeq(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double, let i = Int(exactly: d) { return i }
        return nil
    }
}
