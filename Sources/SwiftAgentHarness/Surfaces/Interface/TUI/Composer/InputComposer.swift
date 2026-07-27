import Foundation

/// Terminal-local multi-line input editor with IME cursor marker support.
///
/// The composer's job is to produce a normalized ``ComposerSubmission`` — the portable
/// inbound envelope. Everything else here (key handling, paste blocks, autocomplete
/// presentation) is surface-local and deliberately non-portable.
public final class InputComposerComponent: TUIComponent, Focusable {
    public var lines: [String]
    public var cursorLine: Int
    public var cursorColumn: Int
    public var isFocused: Bool = true
    public var placeholder: String
    public var autocomplete: AutocompletePopupComponent?

    /// True when any content in the current composition arrived by paste. Sticky until
    /// ``clear()``: provenance describes the submission, and a single keystroke after a
    /// 400-line paste must not relabel it as typed input, because this field feeds the
    /// control-input trust decision.
    public private(set) var lastWasPasted: Bool = false
    public private(set) var lastPasteLineCount: Int = 0

    /// Large pastes are represented in the buffer by a short placeholder token and
    /// expanded back to their full text at submission, so the composer viewport stays
    /// usable without losing a byte of what the user pasted.
    private var pastedBlocks: [String: String] = [:]
    private var pastedBlockCounter = 0

    public init(placeholder: String = "Type a message…", lines: [String] = [""]) {
        self.placeholder = placeholder
        self.lines = lines.isEmpty ? [""] : lines
        self.cursorLine = 0
        self.cursorColumn = lines.first?.count ?? 0
    }

    /// The literal buffer contents, with large pastes still collapsed to placeholders.
    public var text: String {
        lines.joined(separator: "\n")
    }

    /// The buffer with every paste placeholder expanded back to its full text. This is
    /// what gets submitted.
    public var expandedText: String {
        guard !pastedBlocks.isEmpty else { return text }
        var result = text
        for (token, content) in pastedBlocks {
            result = result.replacingOccurrences(of: token, with: content)
        }
        return result
    }

    public var isEmpty: Bool {
        lines.count == 1 && lines[0].isEmpty
    }

    // MARK: - Rendering

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var output: [String] = []
        let prompt = ANSIStyle.color("❯ ", fg: 39)
        let promptWidth = ANSIWidth.visibleWidth(of: prompt)

        if isEmpty {
            // The placeholder used to be gated on `!isFocused`, which never holds — the
            // composer is focused by default and nothing clears it — so an empty composer
            // rendered as a bare prompt with no hint.
            let rendered = embedCursorMarker(
                in: prompt + ANSIStyle.dim(placeholder),
                visibleColumn: promptWidth
            )
            output.append(ANSIStyle.finishLine(ANSITruncate.truncate(rendered, toWidth: width)))
        } else {
            for (index, line) in lines.enumerated() {
                var rendered = index == 0 ? prompt + line : "  " + line
                if isFocused, index == cursorLine {
                    let leading = index == 0 ? prompt : "  "
                    let safeColumn = min(cursorColumn, line.count)
                    let visibleCol = ANSIWidth.visibleWidth(of: leading + String(line.prefix(safeColumn)))
                    rendered = embedCursorMarker(in: rendered, visibleColumn: visibleCol)
                }
                output.append(ANSIStyle.finishLine(ANSITruncate.truncate(rendered, toWidth: width)))
            }
        }

        if let autocomplete, !autocomplete.suggestions.isEmpty {
            output.append(contentsOf: autocomplete.render(width: width))
        }
        return output
    }

    // MARK: - Input

    public func handleInput(_ data: String) {
        if let paste = BracketedPaste.unwrap(data) {
            insertPaste(paste)
            invalidate()
            return
        }

        switch data {
        case "\r":
            // Submission is the app's decision, not the composer's.
            break
        case "\n":
            insertNewline()
        case "\u{7F}", "\u{08}":
            deleteBackward()
        case "\u{1B}[A":
            moveCursor(lineDelta: -1, column: cursorColumn)
        case "\u{1B}[B":
            moveCursor(lineDelta: 1, column: cursorColumn)
        case "\u{1B}[C":
            moveCursor(lineDelta: 0, column: cursorColumn + 1)
        case "\u{1B}[D":
            moveCursor(lineDelta: 0, column: max(0, cursorColumn - 1))
        case "\u{1B}[H", "\u{1B}[1~":
            cursorColumn = 0
        case "\u{1B}[F", "\u{1B}[4~":
            cursorColumn = lines[cursorLine].count
        default:
            // Control bytes and escape sequences must never land in the buffer as literal
            // text: `isASCII` is true for Ctrl-C, Tab and a bare ESC, and a paste can
            // carry arbitrary sequences.
            let sanitized = TUITextSanitizer.sanitizeMultiline(data)
            if !sanitized.isEmpty {
                insertText(sanitized)
            }
        }
        invalidate()
    }

    public func insertPaste(_ paste: BracketedPaste.Result) {
        let content = TUITextSanitizer.sanitizeMultiline(paste.text)
        if paste.isLargePaste {
            pastedBlockCounter += 1
            let token = "[Pasted \(paste.lineCount) lines #\(pastedBlockCounter)]"
            pastedBlocks[token] = content
            insertText(token)
        } else {
            insertText(content)
        }
        lastWasPasted = true
        lastPasteLineCount += paste.lineCount
    }

    public func makeSubmission(
        originSurface: String = "tui",
        inputTrustRaw: String? = MessageInputTrust.directUserEntry.rawValue
    ) -> ComposerSubmission {
        ComposerSubmission(
            text: expandedText,
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
        pastedBlocks = [:]
        lastWasPasted = false
        lastPasteLineCount = 0
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    // MARK: - Editing

    public func insertText(_ text: String) {
        let parts = text.components(separatedBy: "\n")
        guard !parts.isEmpty else { return }

        let line = lines[cursorLine]
        let column = min(cursorColumn, line.count)
        let splitIndex = line.index(line.startIndex, offsetBy: column)
        let head = String(line[..<splitIndex])
        let tail = String(line[splitIndex...])

        if parts.count == 1 {
            lines[cursorLine] = head + parts[0] + tail
            cursorColumn = head.count + parts[0].count
            return
        }

        // Splice: head+first, the untouched middle parts, then last+tail. The previous
        // implementation appended `parts[1]` to a line that already held `parts[0]` and
        // the tail, re-inserted the middle parts, then overwrote the last element — which
        // for a two-part paste was the only element, wiping the paste's first line and
        // the pre-existing buffer with it.
        var inserted: [String] = [head + parts[0]]
        if parts.count > 2 {
            inserted.append(contentsOf: parts[1..<(parts.count - 1)])
        }
        let last = parts[parts.count - 1]
        inserted.append(last + tail)

        lines.replaceSubrange(cursorLine...cursorLine, with: inserted)
        cursorLine += parts.count - 1
        cursorColumn = last.count
    }

    public func insertNewline() {
        let current = lines[cursorLine]
        let column = min(cursorColumn, current.count)
        let index = current.index(current.startIndex, offsetBy: column)
        let tail = String(current[index...])
        lines[cursorLine] = String(current[..<index])
        lines.insert(tail, at: cursorLine + 1)
        cursorLine += 1
        cursorColumn = 0
        invalidate()
    }

    public func deleteBackward() {
        // Every sibling clamps its String index; this one used to trust `cursorColumn`
        // outright and trapped on `String index is out of bounds`.
        let currentCount = lines[cursorLine].count
        let column = min(cursorColumn, currentCount)

        guard column > 0 else {
            guard cursorLine > 0 else { return }
            let previousLength = lines[cursorLine - 1].count
            lines[cursorLine - 1] += lines[cursorLine]
            lines.remove(at: cursorLine)
            cursorLine -= 1
            cursorColumn = previousLength
            return
        }

        var line = lines[cursorLine]
        let index = line.index(line.startIndex, offsetBy: column)
        let previous = line.index(before: index)
        line.remove(at: previous)
        lines[cursorLine] = line
        cursorColumn = column - 1
    }

    private func insertCharacter(_ character: String) {
        insertText(character)
    }

    private func moveCursor(lineDelta: Int, column: Int) {
        if lineDelta != 0 {
            cursorLine = max(0, min(lines.count - 1, cursorLine + lineDelta))
        }
        cursorColumn = max(0, min(lines[cursorLine].count, column))
    }
}
