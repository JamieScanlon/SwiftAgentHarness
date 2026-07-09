import Foundation

/// Exact normalized command-string equivalence for exec denial hygiene.
enum ExecApprovalCommandEquivalence {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    static func normalize(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
