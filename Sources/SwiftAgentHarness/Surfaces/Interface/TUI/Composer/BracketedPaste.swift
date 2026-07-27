import Foundation

public enum BracketedPaste {
    public static let start = "\u{1B}[200~"
    public static let end = "\u{1B}[201~"
    public static let largePasteLineThreshold = 10

    public struct Result: Sendable, Equatable {
        public var text: String
        public var isLargePaste: Bool
        public var lineCount: Int

        public init(text: String, isLargePaste: Bool, lineCount: Int) {
            self.text = text
            self.isLargePaste = isLargePaste
            self.lineCount = lineCount
        }
    }

    public static func unwrap(_ input: String) -> Result? {
        guard input.hasPrefix(start), input.hasSuffix(end) else { return nil }
        let raw = String(input.dropFirst(start.count).dropLast(end.count))
        // xterm, iTerm2 and Terminal.app deliver paste line breaks as CR, not LF.
        // Splitting on LF alone reports a single line, defeats the large-paste
        // threshold, and leaves literal CRs in the buffer that reset the cursor to
        // column 0 mid-row when the composer renders them.
        let inner = normalizeNewlines(raw)
        let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
        return Result(
            text: inner,
            isLargePaste: lines.count > largePasteLineThreshold,
            lineCount: lines.count
        )
    }

    /// The text a composer should insert for a paste: large pastes collapse to a
    /// placeholder so a multi-hundred-line paste does not swamp the composer viewport.
    public static func marker(for result: Result) -> String {
        if result.isLargePaste {
            return "[Pasted \(result.lineCount) lines]"
        }
        return result.text
    }

    static func normalizeNewlines(_ text: String) -> String {
        TUITextSanitizer.normalizedNewlines(text)
    }
}
