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

        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            if paragraph.isEmpty {
                lines.append(ANSIStyle.finishLine(""))
                currentLine = ""
                currentWidth = 0
                if paragraphIndex + 1 < paragraphs.count { continue }
                break
            }
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
                let spaceNeeded = currentLine.isEmpty ? 0 : 1
                if currentWidth + spaceNeeded + wordWidth > width {
                    flushLine(&currentLine, &currentWidth, into: &lines, stylePrefix: &activeStylePrefix)
                }
                if !currentLine.isEmpty {
                    currentLine += " "
                    currentWidth += 1
                }
                currentLine += word
                currentWidth += wordWidth
            }
            flushLine(&currentLine, &currentWidth, into: &lines, stylePrefix: &activeStylePrefix)
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
            if chunk.isEmpty, index < remaining.endIndex {
                let ch = remaining[index]
                chunk = String(ch)
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

    private static func extractTrailingStyle(from line: String) -> String {
        guard let lastEsc = line.lastIndex(of: "\u{1B}") else { return "" }
        let suffix = String(line[lastEsc...])
        if suffix.hasSuffix("m") { return suffix }
        return ""
    }
}
