import Foundation
import Logging

struct TriggerAuditEntry: Codable, Sendable, Equatable {
    var triggerID: String
    var source: TriggerSource
    var trust: CommEnvelopeOriginTrust
    var receivedAt: Int64
    var decision: TriggerActivationDecision
    var sessionID: UUID?
    var loggedAt: Date
    var rootId: String?
    var parentTriggerId: String?
    var correlationId: String?

    init(
        triggerID: String,
        source: TriggerSource,
        trust: CommEnvelopeOriginTrust,
        receivedAt: Int64,
        decision: TriggerActivationDecision,
        sessionID: UUID?,
        loggedAt: Date,
        rootId: String? = nil,
        parentTriggerId: String? = nil,
        correlationId: String? = nil
    ) {
        self.triggerID = triggerID
        self.source = source
        self.trust = trust
        self.receivedAt = receivedAt
        self.decision = decision
        self.sessionID = sessionID
        self.loggedAt = loggedAt
        self.rootId = rootId
        self.parentTriggerId = parentTriggerId
        self.correlationId = correlationId
    }

    static func from(trigger: HarnessTrigger, decision: TriggerActivationDecision, sessionID: UUID? = nil) -> TriggerAuditEntry {
        let correlation = trigger.effectiveCorrelation()
        return TriggerAuditEntry(
            triggerID: trigger.id,
            source: trigger.source,
            trust: trigger.trust,
            receivedAt: trigger.receivedAt,
            decision: decision,
            sessionID: sessionID,
            loggedAt: Date(),
            rootId: correlation.rootId,
            parentTriggerId: correlation.parentTriggerId,
            correlationId: correlation.correlationId
        )
    }
}

struct TriggerAuditLog: Sendable {
    private let logger: Logger
    private let jsonlURL: URL?

    init(logger: Logger, jsonlURL: URL? = nil) {
        self.logger = logger
        self.jsonlURL = jsonlURL
    }

    func record(_ entry: TriggerAuditEntry) {
        logger.info(
            "trigger_audit id=\(entry.triggerID) source=\(entry.source.rawValue) trust=\(entry.trust.rawValue) decision=\(entry.decision.rawValue) session=\(entry.sessionID?.uuidString ?? "nil")"
        )
        guard let jsonlURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let handle = try? FileHandle(forWritingTo: jsonlURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                return
            }
        } else {
            try? Data(line.utf8).write(to: jsonlURL, options: .atomic)
        }
    }
}
