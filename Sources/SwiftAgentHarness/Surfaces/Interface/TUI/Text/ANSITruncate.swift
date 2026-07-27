import Foundation

public enum ANSITruncate: Sendable {
    public static func truncate(_ text: String, toWidth maxWidth: Int, ellipsis: String = "…") -> String {
        guard maxWidth > 0 else { return "" }
        if ANSIWidth.visibleWidth(of: text) <= maxWidth { return text }
        let ellipsisWidth = ANSIWidth.visibleWidth(of: ellipsis)
        let target = max(0, maxWidth - ellipsisWidth)

        var result = ""
        var width = 0
        var pendingStyle = ""
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            if ch == "\u{1B}" {
                let end = ANSIWidth.skipEscape(in: text, from: index)
                let sequence = String(text[index..<end])
                if sequence == CursorMarker.sentinel {
                    // The cursor marker encodes a *position*, so it must stay where it
                    // sits rather than being buffered and flushed after the ellipsis —
                    // otherwise the hardware cursor (and the IME candidate window)
                    // jumps to the right edge whenever a line is truncated.
                    result += pendingStyle
                    pendingStyle = ""
                    result += sequence
                } else {
                    pendingStyle += sequence
                }
                index = end
                continue
            }

            let charWidth = ANSIWidth.characterWidth(ch)
            if width + charWidth > target { break }
            if !pendingStyle.isEmpty {
                result += pendingStyle
                pendingStyle = ""
            }
            result.append(ch)
            width += charWidth
            index = text.index(after: index)
        }

        // Trailing style carries no visible width; keeping it preserves the run's
        // styling through the ellipsis.
        if !pendingStyle.isEmpty { result += pendingStyle }
        return result + ellipsis
    }

    /// Truncates to `width` and right-pads with spaces so the result occupies exactly
    /// `width` visible columns. Callers that splice content into a fixed grid (overlay
    /// compositing, split panes, box interiors) need the padding half as much as the
    /// truncation half.
    public static func fit(_ text: String, toWidth width: Int, ellipsis: String = "…") -> String {
        guard width > 0 else { return "" }
        let clipped = truncate(text, toWidth: width, ellipsis: ellipsis)
        let visible = ANSIWidth.visibleWidth(of: clipped)
        guard visible < width else { return clipped }
        return clipped + String(repeating: " ", count: width - visible)
    }
}
