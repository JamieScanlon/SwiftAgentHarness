import Foundation

/// Parses pre-reply active-memory sub-agent output under the NONE contract.
enum ActiveMemoryRecallOutput: Sendable {
    /// Returns a usable memory note, or `nil` when the model signaled silence / empty.
    static func noteOrNil(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isNoneToken(trimmed) { return nil }
        return trimmed
    }

    /// True when the whole message is the NONE sentinel (optional wrapping punctuation/backticks).
    static func isNoneToken(_ text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("`"), s.hasSuffix("`"), s.count >= 2 {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = s.last, ".,!;:".contains(last) {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.uppercased() == "NONE"
    }
}
