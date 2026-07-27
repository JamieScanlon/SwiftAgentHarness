import Foundation

public enum ANSIWrap: Sendable {
    /// Wraps plain or ANSI-styled text to fit within `width` visible columns.
    public static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [""] }
        if text.isEmpty { return [""] }

        var lines: [String] = []
        var currentLine = ""
        var currentWidth = 0
        var activeStylePrefix = ""

        // `split(separator: "\n")` is Character-based and does not split a CRLF cluster,
        // so an un-sanitized CR+LF would ride into a rendered line measuring zero columns.
        let paragraphs = TUITextSanitizer.normalizedNewlines(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            if paragraph.isEmpty {
                lines.append(ANSIStyle.finishLine(""))
                currentLine = ""
                currentWidth = 0
                if paragraphIndex + 1 < paragraphs.count { continue }
                break
            }
            let linesBeforeParagraph = lines.count
            let words = splitPreservingEscapes(String(paragraph))
            for word in words {
                let wordWidth = ANSIWidth.visibleWidth(of: word)
                if wordWidth > width {
                    flushLine(&currentLine, &currentWidth, into: &lines, stylePrefix: &activeStylePrefix)
                    appendLongWord(word, width: width, into: &lines, stylePrefix: &activeStylePrefix)
                    currentLine = ""
                    currentWidth = 0
                    continue
                }
                let spaceNeeded = currentWidth > 0 ? 1 : 0
                if currentWidth + spaceNeeded + wordWidth > width {
                    flushLine(&currentLine, &currentWidth, into: &lines, stylePrefix: &activeStylePrefix)
                }
                // Compare visible width, not string emptiness: after a flush the line
                // carries a zero-width style prefix, and treating that as content
                // prepends a spurious leading space.
                if currentWidth > 0 {
                    currentLine += " "
                    currentWidth += 1
                }
                currentLine += word
                currentWidth += wordWidth
            }
            // Flush trailing content, and emit a blank line for a paragraph that produced
            // none (a whitespace-only line) rather than silently collapsing it.
            if currentWidth > 0 || lines.count == linesBeforeParagraph {
                flushLine(&currentLine, &currentWidth, into: &lines, stylePrefix: &activeStylePrefix)
            }
        }
        if lines.isEmpty { lines.append(ANSIStyle.finishLine("")) }
        return lines
    }

    private static func flushLine(
        _ currentLine: inout String,
        _ currentWidth: inout Int,
        into lines: inout [String],
        stylePrefix: inout String
    ) {
        lines.append(ANSIStyle.finishLine(currentLine))
        stylePrefix = extractTrailingStyle(from: currentLine)
        currentLine = stylePrefix
        currentWidth = ANSIWidth.visibleWidth(of: stylePrefix)
    }

    private static func appendLongWord(
        _ word: String,
        width: Int,
        into lines: inout [String],
        stylePrefix: inout String
    ) {
        var remaining = word
        var prefix = stylePrefix
        while !remaining.isEmpty {
            var chunk = ""
            var chunkWidth = 0
            var index = remaining.startIndex
            while index < remaining.endIndex {
                let ch = remaining[index]
                if ch == "\u{1B}" {
                    let end = ANSIWidth.skipEscape(in: remaining, from: index)
                    chunk += String(remaining[index..<end])
                    index = end
                    continue
                }
                let w = ANSIWidth.characterWidth(ch)
                if chunkWidth + w > width { break }
                chunk.append(ch)
                chunkWidth += w
                index = remaining.index(after: index)
            }
            if chunkWidth == 0, index < remaining.endIndex {
                let ch = remaining[index]
                // A cluster wider than the whole line can never fit. Emitting it anyway
                // produces an over-wide line, which `TUIComponentRender` turns into a
                // process abort — with the tty still in raw mode.
                chunk = ANSIWidth.characterWidth(ch) > width ? "…" : String(ch)
                index = remaining.index(after: index)
            }
            let line = prefix + chunk
            lines.append(ANSIStyle.finishLine(line))
            prefix = extractTrailingStyle(from: line)
            remaining = index < remaining.endIndex ? String(remaining[index...]) : ""
        }
        stylePrefix = prefix
    }

    private static func splitPreservingEscapes(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == " " {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                index = text.index(after: index)
                continue
            }
            if ch == "\u{1B}" {
                let end = ANSIWidth.skipEscape(in: text, from: index)
                current += String(text[index..<end])
                index = end
                continue
            }
            current.append(ch)
            index = text.index(after: index)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The SGR state still in effect at the end of `line`, so the next wrapped line can
    /// reopen it.
    ///
    /// This must parse escape sequences rather than slicing from the last `ESC`: that
    /// shortcut returns the whole line whenever its final visible character happens to
    /// be `m` (`problem`, `algorithm`, `system`, `stream`, `confirm`, …), which then
    /// gets prepended to the following line — duplicating the text and blowing the
    /// width invariant that `TUIComponentRender` traps on.
    private static func extractTrailingStyle(from line: String) -> String {
        var active = ""
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            guard ch == "\u{1B}" else {
                index = line.index(after: index)
                continue
            }
            let end = ANSIWidth.skipEscape(in: line, from: index)
            let sequence = String(line[index..<end])
            if sequence.hasSuffix("m"), sequence.hasPrefix("\u{1B}[") {
                if sequence == TUIEscapes.styleReset {
                    active = ""
                } else {
                    active += sequence
                }
            }
            index = end
        }
        return active
    }
}
