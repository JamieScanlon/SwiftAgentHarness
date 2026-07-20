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

    /// Hard-caps a memory note; when clipped, appends `…` inside the budget so truncation is visible.
    static func truncatedNote(_ note: String, maxChars: Int) -> String {
        let limit = max(1, maxChars)
        guard note.count > limit else { return note }
        if limit == 1 { return "…" }
        let bodyBudget = limit - 1
        return String(note.prefix(bodyBudget)) + "…"
    }
}
