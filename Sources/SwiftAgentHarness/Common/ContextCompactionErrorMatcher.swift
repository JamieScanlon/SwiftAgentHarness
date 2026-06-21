import Foundation

/// Shared substring matcher for "context window exceeded" provider errors.
///
/// Used by both:
/// - the **reactive trigger** in `HarnessRuntimeSession.startStreamingOrchestrationTask` to detect when
///   the orchestrator has rejected a request as too long, and
/// - the **oversize-retry loop** inside `OllamaContextCompactionSummarizer.summarizeMiddle`
///   to detect when the compaction LLM call itself is being rejected.
///
/// Patterns are compared case-insensitively as substrings against both `error.localizedDescription`
/// and `String(describing: error)` so we catch the message regardless of which Swift/Foundation
/// surface the underlying provider error is wrapped behind.
public enum ContextCompactionErrorMatcher: Sendable {
    /// Returns `true` when any pattern in `patterns` matches a haystack derived from `error`.
    /// An empty `patterns` list never matches.
    public static func isContextWindowExceeded(_ error: Error, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let haystacks = haystackStrings(for: error)
        for pattern in patterns {
            let needle = pattern.lowercased()
            guard !needle.isEmpty else { continue }
            for haystack in haystacks where haystack.contains(needle) {
                return true
            }
        }
        return false
    }

    /// Returns the lowercased strings used as match targets for an error. Visible for testing.
    public static func haystackStrings(for error: Error) -> [String] {
        var out: [String] = []
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            out.append(localized.lowercased())
        }
        out.append(error.localizedDescription.lowercased())
        out.append(String(describing: error).lowercased())
        return out
    }
}
