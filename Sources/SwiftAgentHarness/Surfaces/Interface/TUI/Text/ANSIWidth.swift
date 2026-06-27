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

    public static func characterWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let value = scalar.value
        if (0x1100...0x115F).contains(value)
            || (0x2E80...0x303E).contains(value)
            || (0x3040...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value) {
            return 2
        }
        if character.isNewline { return 0 }
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

    static func skipEscape(in text: String, from start: String.Index) -> String.Index {
        var index = text.index(after: start)
        guard index < text.endIndex else { return text.endIndex }
        let next = text[index]
        if next == "]" {
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
        if next == "_" {
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
        if next == "[" || next == "(" {
            index = text.index(after: index)
            while index < text.endIndex {
                let ch = text[index]
                if ch.isLetter { return text.index(after: index) }
                index = text.index(after: index)
            }
            return text.endIndex
        }
        return text.index(after: start)
    }
}
