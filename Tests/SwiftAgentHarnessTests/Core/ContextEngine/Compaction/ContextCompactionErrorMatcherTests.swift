import Foundation
import SwiftAgentHarness
import Testing

@Suite("ContextCompactionErrorMatcher")
struct ContextCompactionErrorMatcherTests {

    /// All canonical patterns from the plan; `defaultReactiveErrorPatterns` lives on the server-side
    /// `ContextCompactionConfiguration`
    private static let canonicalPatterns: [String] = [
        "prompt too long",
        "context length",
        "maximum context",
        "context window",
        "too many tokens",
        "too large for the model",
    ]

    private struct PlainError: Error, CustomStringConvertible {
        let description: String
    }

    private struct LocalizedFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Test("Each canonical pattern matches case-insensitively in localizedDescription")
    func eachPatternMatchesLocalized() {
        for pattern in Self.canonicalPatterns {
            let upper = pattern.uppercased()
            let mixed = "Provider rejected request: \(upper) ABC"
            let err = LocalizedFailure(message: mixed)
            #expect(
                ContextCompactionErrorMatcher.isContextWindowExceeded(err, patterns: Self.canonicalPatterns),
                "pattern '\(pattern)' should match in '\(mixed)'"
            )
        }
    }

    @Test("Each canonical pattern matches via String(describing:) when no LocalizedError")
    func eachPatternMatchesDescribing() {
        for pattern in Self.canonicalPatterns {
            let upper = pattern.uppercased()
            let err = PlainError(description: "wrapped error: \(upper)")
            #expect(
                ContextCompactionErrorMatcher.isContextWindowExceeded(err, patterns: Self.canonicalPatterns),
                "pattern '\(pattern)' should match via String(describing:)"
            )
        }
    }

    @Test("Non-matching errors do not trip the matcher")
    func nonMatchingErrorsAreIgnored() {
        let timeout = URLError(.timedOut)
        #expect(!ContextCompactionErrorMatcher.isContextWindowExceeded(timeout, patterns: Self.canonicalPatterns))

        let unrelated = LocalizedFailure(message: "rate limit exceeded")
        #expect(!ContextCompactionErrorMatcher.isContextWindowExceeded(unrelated, patterns: Self.canonicalPatterns))

        let serverError = LocalizedFailure(message: "server unavailable")
        #expect(!ContextCompactionErrorMatcher.isContextWindowExceeded(serverError, patterns: Self.canonicalPatterns))
    }

    @Test("Empty pattern list never matches anything")
    func emptyPatternsNeverMatch() {
        let err = LocalizedFailure(message: "prompt too long")
        #expect(!ContextCompactionErrorMatcher.isContextWindowExceeded(err, patterns: []))
    }

    @Test("Empty/whitespace-only pattern entries are skipped, others still evaluated")
    func emptyEntriesAreSkipped() {
        let err = LocalizedFailure(message: "context window exceeded")
        let patterns = ["", "context window", ""]
        #expect(ContextCompactionErrorMatcher.isContextWindowExceeded(err, patterns: patterns))
    }

    @Test("Custom non-canonical pattern still matches when supplied")
    func customPattern() {
        let err = LocalizedFailure(message: "the conversation overflowed")
        #expect(
            ContextCompactionErrorMatcher.isContextWindowExceeded(err, patterns: ["overflowed"])
        )
    }

    @Test("haystackStrings includes localizedDescription, errorDescription, and String(describing:)")
    func haystacksContainAllSurfaces() {
        let err = LocalizedFailure(message: "Prompt Too Long detail")
        let stacks = ContextCompactionErrorMatcher.haystackStrings(for: err)
        // All entries are lowercased.
        #expect(stacks.allSatisfy { $0 == $0.lowercased() })
        // `errorDescription` surface is included in addition to `localizedDescription` and
        // `String(describing:)`. We expect at least one haystack to contain the lowercased text.
        #expect(stacks.contains { $0.contains("prompt too long") })
    }
}
