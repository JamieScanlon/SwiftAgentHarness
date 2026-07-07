import Foundation

public enum BracketedPaste {
    public static let start = "\u{1B}[200~"
    public static let end = "\u{1B}[201~"
    public static let largePasteLineThreshold = 10

    public struct Result: Sendable, Equatable {
        public var text: String
        public var isLargePaste: Bool
        public var lineCount: Int
    }

    public static func unwrap(_ input: String) -> Result? {
        guard input.hasPrefix(start), input.hasSuffix(end) else { return nil }
        let inner = String(input.dropFirst(start.count).dropLast(end.count))
        let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
        return Result(
            text: inner,
            isLargePaste: lines.count > largePasteLineThreshold,
            lineCount: lines.count
        )
    }

    public static func marker(for result: Result) -> String {
        if result.isLargePaste {
            return "[Pasted \(result.lineCount) lines]"
        }
        return result.text
    }
}
