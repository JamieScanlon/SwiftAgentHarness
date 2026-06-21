//
//  Hardened MATCH operand construction for SQLite FTS5 (prefix/phrases; no raw user paste).
//

import Foundation

enum FTS5QuerySanitizer {
    /// Builds a conservative `MATCH` operand: whitespace-separated terms become mandatory `AND` phrases.
    /// Double quotes inside terms are escaped per FTS5 phrase rules.
    static func matchAndPhrases(_ userQuery: String) -> String {
        let trimmed = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        return parts.map { phrase in
            let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let escaped = trimmedPhrase
                .replacingOccurrences(of: "\"", with: "\"\"")
                .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            let safe = String(String.UnicodeScalarView(escaped))
            return "\"\(safe)\""
        }.joined(separator: " AND ")
    }

    /// Plain phrase terms extracted from a ``matchAndPhrases`` operand for in-memory substring search (mirrors FTS5 AND semantics without SQLite).
    static func phraseTerms(fromMatchOperand matchOperand: String) -> [String] {
        let trimmed = matchOperand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: " AND ", omittingEmptySubsequences: false).map { part in
            var s = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
                s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
