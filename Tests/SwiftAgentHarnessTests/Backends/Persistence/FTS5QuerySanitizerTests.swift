import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("FTS5 query sanitizer (FTS)")
struct FTS5QuerySanitizerTests {
    @Test func matchAndPhrasesANDsQuotedTokens() {
        let m = FTS5QuerySanitizer.matchAndPhrases("foo bar")
        #expect(m == "\"foo\" AND \"bar\"")
    }

    @Test func matchAndPhrasesEscapesQuotes() {
        let m = FTS5QuerySanitizer.matchAndPhrases("a\"b")
        #expect(m == "\"a\"\"b\"")
    }

    @Test func matchAndPhrasesStripsControls() {
        let m = FTS5QuerySanitizer.matchAndPhrases("x\u{0}y")
        #expect(!m.contains("\u{0}"))
    }

    @Test func phraseTermsRoundTrip() {
        let m = FTS5QuerySanitizer.matchAndPhrases("one two")
        let terms = FTS5QuerySanitizer.phraseTerms(fromMatchOperand: m)
        #expect(terms == ["one", "two"])
    }

    @Test func phraseTermsEmptyForBlank() {
        #expect(FTS5QuerySanitizer.phraseTerms(fromMatchOperand: "").isEmpty)
        #expect(FTS5QuerySanitizer.phraseTerms(fromMatchOperand: "   ").isEmpty)
    }

    @Test func matchAndPhrasesCollapsesWhitespaceAndTrims() {
        let m = FTS5QuerySanitizer.matchAndPhrases("  alpha\t \n beta  ")
        #expect(m == "\"alpha\" AND \"beta\"")
    }
}
