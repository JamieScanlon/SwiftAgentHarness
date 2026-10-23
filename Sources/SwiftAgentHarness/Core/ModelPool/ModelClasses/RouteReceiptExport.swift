import CryptoKit
import Foundation

/// Sanitized wire form of a ``RouteReceipt`` for the `conversation/{id}/events` bus (`semanticKind == routeReceipt`).
///
/// Redaction happens here, at the emit boundary: receipts never carry request or response content, and vendor
/// request ids are replaced by a short hash so the record can be correlated with vendor support without exposing them.
public struct RouteReceiptWire: Codable, Sendable, Equatable {
    public struct Resolved: Codable, Sendable, Equatable {
        public var modelID: String
        public var versionServed: String?
        public var bindingID: String
        public var surface: String
    }

    public struct Fallback: Codable, Sendable, Equatable {
        public var from: String
        public var reason: String
    }

    public struct Decision: Codable, Sendable, Equatable {
        public var question: String
        public var verdict: String
        public var reason: String
        public var modelVersion: String?
        public var value: Double?
    }

    public var v: Int
    public var callID: UUID
    public var conversationID: UUID?
    public var runID: UUID?
    public var role: String?
    public var contract: String
    public var requested: String
    public var resolved: Resolved?
    public var aliasResolved: [String: String]?
    public var rankedOut: [[String: String]]
    public var cascadeEscalated: Bool?
    public var cascadeReason: String?
    public var cascadeFirstStage: Resolved?
    public var fallback: [Fallback]
    public var guarantee: String?
    public var costUSD: Double?
    public var latencyMs: Double
    public var requestIDHashes: [String]
    public var cacheHit: Bool
    public var decision: Decision?
    public var errorClassification: String?
    /// One line for surfaces: "answered by X (fallback from Y)".
    public var summary: String
}

public extension RouteReceipt {
    var wire: RouteReceiptWire {
        func resolved(_ value: Resolved?) -> RouteReceiptWire.Resolved? {
            value.map {
                RouteReceiptWire.Resolved(
                    modelID: $0.modelID, versionServed: $0.versionServed, bindingID: $0.bindingID, surface: $0.surface.rawValue
                )
            }
        }
        return RouteReceiptWire(
            v: 1,
            callID: callID,
            conversationID: conversationID,
            runID: runID,
            role: role?.rawValue,
            contract: contract.rawValue,
            requested: requested,
            resolved: resolved(self.resolved),
            aliasResolved: aliasResolved.map { ["alias": $0.alias, "to": $0.to] },
            rankedOut: rankedOut.map { ["modelID": $0.modelID, "reason": $0.reason] },
            cascadeEscalated: cascade?.escalated,
            cascadeReason: cascade?.reason,
            cascadeFirstStage: resolved(cascade?.firstStage),
            fallback: fallback.map { RouteReceiptWire.Fallback(from: $0.from, reason: $0.reason.rawValue) },
            guarantee: guarantee?.rawValue,
            costUSD: costUSD,
            latencyMs: latencyMs,
            requestIDHashes: requestIDs.map(Self.hashRequestID),
            cacheHit: cacheHit,
            decision: decision.map {
                RouteReceiptWire.Decision(
                    question: $0.question, verdict: $0.verdict.rawValue, reason: Self.describe($0.reason),
                    modelVersion: $0.modelVersion, value: $0.value
                )
            },
            errorClassification: errorClassification?.rawValue,
            summary: summary
        )
    }

    /// "gatekeeper answered by jev-1.13.0 via typesafe/jev-1.13.0 (fallback from a/primary: transient) → act"
    var summary: String {
        let subject = role?.rawValue ?? contract.rawValue
        guard let resolved else {
            let cause = errorClassification?.rawValue ?? "no candidate"
            return "\(subject) unanswered (\(cause))" + (decision.map { " → \($0.verdict.rawValue)" } ?? "")
        }
        var text = "\(subject) answered by \(resolved.versionServed ?? resolved.modelID) via \(resolved.bindingID)"
        var notes: [String] = []
        if let alias = aliasResolved { notes.append("alias \(alias.alias)") }
        if !fallback.isEmpty {
            notes.append("fallback from " + fallback.map { "\($0.from): \($0.reason.rawValue)" }.joined(separator: ", "))
        }
        if cascade?.escalated == true, let first = cascade?.firstStage {
            notes.append("escalated from \(first.versionServed ?? first.modelID)")
        }
        if cacheHit { notes.append("cached") }
        if !notes.isEmpty { text += " (" + notes.joined(separator: "; ") + ")" }
        if let decision { text += " → \(decision.verdict.rawValue)" }
        return text
    }

    static func hashRequestID(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ reason: DecisionEvaluation.Reason) -> String {
        switch reason {
        case .band(let verdict): return "band:\(verdict.rawValue)"
        case .rangeGap: return "range-gap"
        case .untunedVersion: return "untuned-version"
        case .uncalibrated: return "uncalibrated"
        case .unavailableAnswer: return "unavailable-answer"
        case .missingAnswer: return "missing-answer"
        case .refused: return "refused"
        case .error: return "error"
        }
    }
}

/// Publishes receipts onto `conversation/{id}/events` as transient `routeReceipt` events. Receipts for calls made
/// outside a conversation have no topic and are skipped (pair with another recorder to keep them).
public struct ConversationEventsRouteReceiptRecorder: RouteReceiptRecording {
    private let publisher: any ConversationTopicPublishing

    public init(publisher: any ConversationTopicPublishing) {
        self.publisher = publisher
    }

    public func record(_ receipt: RouteReceipt) async {
        guard let conversationID = receipt.conversationID else { return }
        await publisher.publishTransientConversationEvent(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.routeReceiptPayload(receipt.wire),
            runID: receipt.runID ?? receipt.callID,
            modelCallId: receipt.callID
        )
    }
}

/// Sends every receipt to each recorder in order (for example, the event bus plus an in-memory audit log).
public struct CompositeRouteReceiptRecorder: RouteReceiptRecording {
    private let recorders: [any RouteReceiptRecording]

    public init(_ recorders: [any RouteReceiptRecording]) {
        self.recorders = recorders
    }

    public func record(_ receipt: RouteReceipt) async {
        for recorder in recorders {
            await recorder.record(receipt)
        }
    }
}
