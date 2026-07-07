import Foundation

public enum ANSITruncate: Sendable {
    public static func truncate(_ text: String, toWidth maxWidth: Int, ellipsis: String = "…") -> String {
        guard maxWidth > 0 else { return "" }
        if visibleWidth(text) <= maxWidth { return text }
        let ellipsisWidth = ANSIWidth.visibleWidth(of: ellipsis)
        let target = max(0, maxWidth - ellipsisWidth)
        var result = ""
        var width = 0
        var index = text.startIndex
        var pendingEscape = ""
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\u{1B}" {
                let end = ANSIWidth.skipEscape(in: text, from: index)
                pendingEscape += String(text[index..<end])
                index = end
                continue
            }
            let charWidth = ANSIWidth.characterWidth(ch)
            if width + charWidth > target {
                break
            }
            if !pendingEscape.isEmpty {
                result += pendingEscape
                pendingEscape = ""
            }
            result.append(ch)
            width += charWidth
            index = text.index(after: index)
        }
        if !pendingEscape.isEmpty { result += pendingEscape }
        return result + ellipsis
    }

    private static func visibleWidth(_ text: String) -> Int {
        ANSIWidth.visibleWidth(of: text)
    }
}
