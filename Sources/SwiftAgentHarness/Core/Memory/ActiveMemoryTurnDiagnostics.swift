import Foundation

enum ActiveMemoryRecallStatus: String, Sendable, Equatable {
    case ok
    case none
    case skipped
    case timeout
    case error
    case disabled
}

/// Per-turn observability for active-memory pre-reply recall.
struct ActiveMemoryTurnDiagnostics: Sendable, Equatable {
    var status: ActiveMemoryRecallStatus
    var elapsedMs: Int
    var queryMode: ActiveMemoryQueryMode
    var summaryChars: Int
    var note: String?
    var skipReason: String?

    static func disabled(
        reason: String,
        queryMode: ActiveMemoryQueryMode,
        elapsedMs: Int = 0
    ) -> ActiveMemoryTurnDiagnostics {
        ActiveMemoryTurnDiagnostics(
            status: .disabled,
            elapsedMs: elapsedMs,
            queryMode: queryMode,
            summaryChars: 0,
            note: nil,
            skipReason: reason
        )
    }

    static func skipped(
        reason: String,
        queryMode: ActiveMemoryQueryMode,
        elapsedMs: Int = 0
    ) -> ActiveMemoryTurnDiagnostics {
        ActiveMemoryTurnDiagnostics(
            status: .skipped,
            elapsedMs: elapsedMs,
            queryMode: queryMode,
            summaryChars: 0,
            note: nil,
            skipReason: reason
        )
    }

    var statusLine: String {
        "Active Memory: status=\(status.rawValue) elapsed=\(elapsedMs)ms query=\(queryMode.rawValue) summary=\(summaryChars) chars"
    }

    var debugLine: String? {
        guard let note, !note.isEmpty else { return nil }
        return "Active Memory Debug: \(note)"
    }

    func followUpContent(verbose: Bool, trace: Bool) -> String? {
        var lines: [String] = []
        if verbose {
            lines.append(statusLine)
        }
        if trace, let debugLine {
            lines.append(debugLine)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

struct ActiveMemoryRecallOutcome: Sendable, Equatable {
    var note: String?
    var diagnostics: ActiveMemoryTurnDiagnostics

    static func disabled(
        reason: String,
        queryMode: ActiveMemoryQueryMode
    ) -> ActiveMemoryRecallOutcome {
        ActiveMemoryRecallOutcome(
            note: nil,
            diagnostics: .disabled(reason: reason, queryMode: queryMode)
        )
    }

    static func skipped(
        reason: String,
        queryMode: ActiveMemoryQueryMode
    ) -> ActiveMemoryRecallOutcome {
        ActiveMemoryRecallOutcome(
            note: nil,
            diagnostics: .skipped(reason: reason, queryMode: queryMode)
        )
    }
}
