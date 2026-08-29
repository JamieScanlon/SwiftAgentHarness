import Foundation

public struct FileDiffHunk: Sendable, Equatable {
    public var oldStart: Int
    public var newStart: Int
    public var lines: [FileDiffLine]

    public init(oldStart: Int, newStart: Int, lines: [FileDiffLine]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

public struct FileDiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, addition, deletion }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public final class FileDiffViewComponent: TUIComponent {
    public var filePath: String
    public var hunks: [FileDiffHunk]

    public init(filePath: String, hunks: [FileDiffHunk] = []) {
        self.filePath = filePath
        self.hunks = hunks
    }

    public func render(width: Int) -> [String] {
        var lines: [String] = []
        lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(ANSIStyle.bold("📄 \(filePath)"), toWidth: width)))
        for hunk in hunks {
            let header = "@@ -\(hunk.oldStart) +\(hunk.newStart) @@"
            lines.append(ANSIStyle.finishLine(ANSIStyle.dim(ANSITruncate.truncate(header, toWidth: width))))
            for diffLine in hunk.lines {
                let styled: String
                switch diffLine.kind {
                case .context:
                    styled = "  \(diffLine.text)"
                case .addition:
                    styled = ANSIStyle.color("+ \(diffLine.text)", fg: 82)
                case .deletion:
                    styled = ANSIStyle.color("- \(diffLine.text)", fg: 196)
                }
                lines.append(contentsOf: ANSIWrap.wrap(styled, width: width))
            }
        }
        return lines
    }

    public func invalidate() {}
}
