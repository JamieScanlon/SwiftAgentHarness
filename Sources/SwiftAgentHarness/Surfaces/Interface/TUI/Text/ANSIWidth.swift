import Foundation

/// Visible-width measurement for terminal text, ignoring ANSI/SGR/OSC-8/APC escapes.
public enum ANSIWidth: Sendable {
    public static func visibleWidth(of text: String) -> Int {
        var width = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\u{1B}" {
                index = skipEscape(in: text, from: index)
                continue
            }
            width += characterWidth(ch)
            index = text.index(after: index)
        }
        return width
    }

    /// Display columns occupied by one grapheme cluster.
    ///
    /// Measured on the whole cluster, not just its first scalar: an emoji ZWJ family,
    /// a regional-indicator flag pair and a `VS16`-promoted symbol are each a single
    /// cluster that occupies two columns. Getting this wrong overflows every line
    /// containing an emoji and desynchronises the differential renderer's row
    /// accounting, because the real terminal wraps where the measurement said it
    /// would not.
    public static func characterWidth(_ character: Character) -> Int {
        if character.isNewline { return 0 }
        let scalars = Array(character.unicodeScalars)
        guard let first = scalars.first else { return 0 }

        // Regional-indicator pair — a flag renders as one double-width cell.
        if scalars.count >= 2,
           isRegionalIndicator(first.value),
           isRegionalIndicator(scalars[1].value) {
            return 2
        }

        // Emoji ZWJ sequences and VS16-promoted symbols take emoji presentation. Guarded
        // on cluster length so a stray joiner arriving on its own stays zero width.
        if scalars.count > 1 {
            for scalar in scalars {
                if scalar.value == 0x200D { return 2 }  // ZERO WIDTH JOINER
                if scalar.value == 0xFE0F { return 2 }  // VARIATION SELECTOR-16
            }
        }

        // VS15 explicitly requests text presentation — one column.
        if scalars.contains(where: { $0.value == 0xFE0E }) { return 1 }

        if first.properties.isEmojiPresentation { return 2 }
        if isWideScalar(first.value) { return 2 }
        if isZeroWidthScalar(first) { return 0 }
        return 1
    }

    public static func stripANSI(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\u{1B}" {
                index = skipEscape(in: text, from: index)
                continue
            }
            result.append(ch)
            index = text.index(after: index)
        }
        return result
    }

    /// Returns the index just past the escape sequence beginning at `start`.
    static func skipEscape(in text: String, from start: String.Index) -> String.Index {
        var index = text.index(after: start)
        guard index < text.endIndex else { return text.endIndex }
        let next = text[index]

        if next == "]" {
            // OSC — terminated by BEL or ST. Note the terminator search must not stop
            // at an arbitrary letter: an OSC-8 hyperlink URL contains plenty of them.
            index = text.index(after: index)
            while index < text.endIndex {
                let ch = text[index]
                if ch == "\u{7}" { return text.index(after: index) }
                if ch == "\u{1B}", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "\\" {
                    return text.index(index, offsetBy: 2)
                }
                index = text.index(after: index)
            }
            return text.endIndex
        }

        if next == "_" || next == "P" || next == "^" {
            // APC (the cursor marker) / DCS / PM — terminated by ST.
            index = text.index(after: index)
            while index < text.endIndex {
                let ch = text[index]
                if ch == "\u{1B}", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "\\" {
                    return text.index(index, offsetBy: 2)
                }
                index = text.index(after: index)
            }
            return text.endIndex
        }

        if next == "[" {
            // CSI — the final byte is 0x40...0x7E, which includes `~`. Scanning for
            // `isLetter` never terminates `ESC[200~` and swallows the text after it.
            index = text.index(after: index)
            while index < text.endIndex {
                if isCSIFinalByte(text[index]) { return text.index(after: index) }
                index = text.index(after: index)
            }
            return text.endIndex
        }

        if next == "(" || next == ")" || next == "#" {
            // Charset / line-attribute selection: one more byte.
            let after = text.index(after: index)
            return after < text.endIndex ? text.index(after: after) : text.endIndex
        }

        // Two-character escape.
        return text.index(after: index)
    }

    static func isCSIFinalByte(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (0x40...0x7E).contains(scalar.value)
    }

    private static func isRegionalIndicator(_ value: UInt32) -> Bool {
        (0x1F1E6...0x1F1FF).contains(value)
    }

    private static func isZeroWidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B, 0x200C, 0x200D, 0xFEFF:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    private static func isWideScalar(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || (0x2E80...0x303E).contains(value)
            || (0x3041...0x33FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xA000...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x16FE0...0x16FE4).contains(value)
            || (0x17000...0x187F7).contains(value)
            || (0x18800...0x18CD5).contains(value)
            || (0x1B000...0x1B2FB).contains(value)
            || (0x1F004...0x1F004).contains(value)
            || (0x1F300...0x1F64F).contains(value)
            || (0x1F680...0x1F6FF).contains(value)
            || (0x1F900...0x1F9FF).contains(value)
            || (0x1FA70...0x1FAFF).contains(value)
            || (0x20000...0x2FFFD).contains(value)
            || (0x30000...0x3FFFD).contains(value)
    }
}
