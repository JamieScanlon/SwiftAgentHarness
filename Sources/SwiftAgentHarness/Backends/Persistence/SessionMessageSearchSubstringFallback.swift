//
//  Substring search fallback for InMemoryHarnessSessionPersistence (no FTS5).
//

import Foundation

enum SessionMessageSearchSubstringFallback: Sendable {
    /// Score used when BM25 is unknown so v2 SQLite hits (lower `bm25`) sort ahead in merged search.
    static let nonFTSScoreRank: Double = 1000

    static func contentMatchesPhrases(_ content: String, phrases: [String]) -> Bool {
        guard !phrases.isEmpty else { return false }
        for p in phrases {
            if p.isEmpty { continue }
            if content.range(of: p, options: .caseInsensitive) == nil { return false }
        }
        return true
    }

    /// Best-effort excerpt with the same highlight markers as SQLite `snippet()` (first phrase match).
    static func highlightedSnippet(content: String, phrases: [String]) -> String {
        guard let needle = phrases.first(where: { !$0.isEmpty }),
              let range = content.range(of: needle, options: .caseInsensitive)
        else {
            return String(content.prefix(200))
        }
        let pad = 32
        let low = content.index(range.lowerBound, offsetBy: -pad, limitedBy: content.startIndex) ?? content.startIndex
        let high = content.index(range.upperBound, offsetBy: pad, limitedBy: content.endIndex) ?? content.endIndex
        let ell = SessionFTS5SearchConstants.snippetEllipsis
        let hlS = SessionFTS5SearchConstants.snippetHighlightStart
        let hlE = SessionFTS5SearchConstants.snippetHighlightEnd
        let before = String(content[low..<range.lowerBound])
        let matchText = String(content[range])
        let after = String(content[range.upperBound..<high])
        let lead = low > content.startIndex ? ell : ""
        let trail = high < content.endIndex ? ell : ""
        return "\(lead)\(before)\(hlS)\(matchText)\(hlE)\(after)\(trail)"
    }
}
