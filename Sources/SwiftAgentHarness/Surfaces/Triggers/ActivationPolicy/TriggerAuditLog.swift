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
