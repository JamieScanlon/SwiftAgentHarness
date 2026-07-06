import Foundation

/// Terminal-local multi-line input editor with IME cursor marker support.
public final class InputComposerComponent: TUIComponent, Focusable {
    public var lines: [String]
    public var cursorLine: Int
    public var cursorColumn: Int
    public var isFocused: Bool = true
    public var placeholder: String
    public var autocomplete: AutocompletePopupComponent?
    public private(set) var lastPasteLineCount: Int = 0
    public private(set) var lastWasPasted: Bool = false

    public init(placeholder: String = "Type a message…", lines: [String] = [""]) {
        self.placeholder = placeholder
        self.lines = lines.isEmpty ? [""] : lines
        self.cursorLine = 0
        self.cursorColumn = lines.first?.count ?? 0
    }

    public var text: String {
        lines.joined(separator: "\n")
    }

    public func render(width: Int) -> [String] {
        var output: [String] = []
        let prompt = ANSIStyle.color("❯ ", fg: 39)
        if lines.count == 1, lines[0].isEmpty, !isFocused {
            output.append(ANSIStyle.finishLine(ANSITruncate.truncate(prompt + ANSIStyle.dim(placeholder), toWidth: width)))
            return output
        }
        for (index, line) in lines.enumerated() {
            var rendered = index == 0 ? prompt + line : "  " + line
            if isFocused, index == cursorLine {
                let visibleCol = ANSIWidth.visibleWidth(of: index == 0 ? prompt + String(line.prefix(cursorColumn)) : "  " + String(line.prefix(cursorColumn)))
                rendered = embedCursorMarker(in: rendered, visibleColumn: visibleCol)
            }
            output.append(ANSIStyle.finishLine(ANSITruncate.truncate(rendered, toWidth: width)))
        }
        if let autocomplete, !autocomplete.suggestions.isEmpty {
            output.append(contentsOf: autocomplete.render(width: width))
        }
        return output
    }

    public func handleInput(_ data: String) {
        if let paste = BracketedPaste.unwrap(data) {
            insertText(paste.text)
            lastWasPasted = true
            lastPasteLineCount = paste.lineCount
            invalidate()
            return
        }
        lastWasPasted = false
        lastPasteLineCount = 0

        switch data {
        case "\r":
            break
        case "\n":
            insertNewline()
        case "\u{7F}", "\u{08}": deleteBackward()
        case "\u{1B}[A": moveCursor(lineDelta: -1, column: cursorColumn)
        case "\u{1B}[B": moveCursor(lineDelta: 1, column: cursorColumn)
        case "\u{1B}[C": moveCursor(lineDelta: 0, column: cursorColumn + 1)
        case "\u{1B}[D": moveCursor(lineDelta: 0, column: max(0, cursorColumn - 1))
        default:
            if data.count == 1, let ch = data.first, ch.isASCII, !ch.isNewline {
                insertCharacter(String(ch))
            } else if !data.hasPrefix("\u{1B}") {
                insertText(data)
            }
        }
        invalidate()
    }

    public func makeSubmission(
        originSurface: String = "tui",
        inputTrustRaw: String? = MessageInputTrust.directUserEntry.rawValue
    ) -> ComposerSubmission {
        ComposerSubmission(
            text: text,
            provenance: ComposerProvenance(
                originSurface: originSurface,
                inputTrustRaw: inputTrustRaw,
                wasPasted: lastWasPasted,
                pasteLineCount: lastPasteLineCount
            )
        )
    }

    public func clear() {
        lines = [""]
        cursorLine = 0
        cursorColumn = 0
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    private func insertCharacter(_ character: String) {
        var line = lines[cursorLine]
        let index = line.index(line.startIndex, offsetBy: min(cursorColumn, line.count))
        line.insert(contentsOf: character, at: index)
        lines[cursorLine] = line
        cursorColumn += character.count
    }

    private func insertText(_ text: String) {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }
        if parts.count == 1 {
            insertCharacter(parts[0])
            return
        }
        var first = lines[cursorLine]
        let index = first.index(first.startIndex, offsetBy: min(cursorColumn, first.count))
        first.insert(contentsOf: parts[0], at: index)
        lines[cursorLine] = first
        var newLines = [lines[cursorLine] + parts[1]]
        if parts.count > 2 {
            newLines.insert(contentsOf: parts[1..<(parts.count - 1)], at: 1)
        }
        let lastPart = parts.last ?? ""
        newLines[newLines.count - 1] = lastPart
        lines = Array(lines.prefix(cursorLine)) + newLines + Array(lines.dropFirst(cursorLine + 1))
        cursorLine = min(lines.count - 1, cursorLine + parts.count - 1)
        cursorColumn = lastPart.count
    }

    private func insertNewline() {
        var current = lines[cursorLine]
        let index = current.index(current.startIndex, offsetBy: min(cursorColumn, current.count))
        let tail = String(current[index...])
        current = String(current[..<index])
        lines[cursorLine] = current
        lines.insert(tail, at: cursorLine + 1)
        cursorLine += 1
        cursorColumn = 0
    }

    private func deleteBackward() {
        guard cursorColumn > 0 else {
            if cursorLine > 0 {
                let previousLength = lines[cursorLine - 1].count
                lines[cursorLine - 1] += lines[cursorLine]
                lines.remove(at: cursorLine)
                cursorLine -= 1
                cursorColumn = previousLength
            }
            return
        }
        var line = lines[cursorLine]
        let index = line.index(line.startIndex, offsetBy: cursorColumn)
        let prev = line.index(before: index)
        line.remove(at: prev)
        lines[cursorLine] = line
        cursorColumn -= 1
    }

    private func moveCursor(lineDelta: Int, column: Int) {
        if lineDelta != 0 {
            cursorLine = max(0, min(lines.count - 1, cursorLine + lineDelta))
        }
        cursorColumn = max(0, min(lines[cursorLine].count, column))
    }
}
