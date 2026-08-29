import Foundation

/// A decoded terminal key event.
///
/// Comparing whole read buffers against string literals (`if data == "\r"`) is not a
/// substitute for decoding: one `read()` routinely returns several keystrokes at once,
/// so fast typing produces `"abc\r"` — which matches nothing, falls through to the
/// composer, and silently never submits.
public enum TUIKey: Sendable, Equatable {
    case enter
    /// Shift-Enter / Alt-Enter / Ctrl-J — insert a line break rather than submitting.
    case newline
    case backspace
    case delete
    case tab
    case backTab
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    /// Ctrl-C.
    case interrupt
    /// Ctrl-D on an empty composer.
    case endOfTransmission
    case text(String)
    case paste(BracketedPaste.Result)
    /// A recognized-but-unhandled escape sequence, preserved for diagnostics.
    case unhandled(String)
}

/// Incremental decoder from raw terminal bytes to ``TUIKey`` values.
///
/// Holds an incomplete escape sequence across reads. A lone trailing `ESC` is treated as
/// the Escape key, because terminals emit multi-byte sequences within a single read and
/// waiting for a disambiguating timeout would make Escape feel broken.
public struct TUIKeyDecoder: Sendable {
    private var pending = ""

    public init() {}

    public mutating func decode(_ data: String) -> [TUIKey] {
        // A complete bracketed-paste envelope arrives pre-assembled from
        // ``BracketedPasteAccumulator`` and is not keyboard input.
        if let paste = BracketedPaste.unwrap(data) {
            return [.paste(paste)]
        }

        let buffer = pending + data
        pending = ""
        var keys: [TUIKey] = []
        var textRun = ""

        func flushText() {
            if !textRun.isEmpty {
                keys.append(.text(textRun))
                textRun = ""
            }
        }

        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]

            if character == "\u{1B}" {
                let isLastCharacter = buffer.index(after: index) == buffer.endIndex
                if isLastCharacter {
                    flushText()
                    keys.append(.escape)
                    index = buffer.index(after: index)
                    continue
                }
                if let (key, next) = Self.parseEscape(buffer, from: index) {
                    flushText()
                    keys.append(key)
                    index = next
                    continue
                }
                // Incomplete sequence: hold it for the next read.
                flushText()
                pending = String(buffer[index...])
                return keys
            }

            if let control = Self.controlKey(for: character) {
                flushText()
                keys.append(control)
                index = buffer.index(after: index)
                continue
            }

            textRun.append(character)
            index = buffer.index(after: index)
        }

        flushText()
        return keys
    }

    /// Emits any held partial sequence as literal text. Call when input has gone idle.
    public mutating func flush() -> [TUIKey] {
        guard !pending.isEmpty else { return [] }
        let held = pending
        pending = ""
        if held == "\u{1B}" { return [.escape] }
        return [.unhandled(held)]
    }

    private static func controlKey(for character: Character) -> TUIKey? {
        switch character {
        case "\r\n": return .enter
        case "\r": return .enter
        case "\n": return .newline
        case "\u{7F}", "\u{08}": return .backspace
        case "\u{09}": return .tab
        case "\u{03}": return .interrupt
        case "\u{04}": return .endOfTransmission
        default:
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
            // Remaining C0 controls are dropped rather than typed into the buffer.
            return scalar.value < 0x20 ? .unhandled(String(character)) : nil
        }
    }

    /// Parses one escape sequence, returning `nil` when it is incomplete.
    private static func parseEscape(_ text: String, from start: String.Index) -> (TUIKey, String.Index)? {
        let afterESC = text.index(after: start)
        guard afterESC < text.endIndex else { return nil }
        let lead = text[afterESC]

        // Alt-Enter / Esc-Enter inserts a line break.
        if lead == "\r" || lead == "\n" || lead == "\r\n" {
            return (.newline, text.index(after: afterESC))
        }

        if lead == "[" || lead == "O" {
            var index = text.index(after: afterESC)
            var params = ""
            while index < text.endIndex, !ANSIWidth.isCSIFinalByte(text[index]) {
                params.append(text[index])
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            let final = text[index]
            let next = text.index(after: index)
            let sequence = String(text[start..<next])
            return (key(final: final, params: params, sequence: sequence), next)
        }

        // Alt-<key>: treat the modified character as plain text.
        let next = text.index(after: afterESC)
        return (.unhandled(String(text[start..<next])), next)
    }

    private static func key(final: Character, params: String, sequence: String) -> TUIKey {
        switch final {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H": return .home
        case "F": return .end
        case "Z": return .backTab
        case "~":
            switch params {
            case "1", "7": return .home
            case "3": return .delete
            case "4", "8": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            default: return .unhandled(sequence)
            }
        default:
            return .unhandled(sequence)
        }
    }
}

public extension TUIKey {
    /// The raw byte sequence a component's legacy `handleInput(_:)` expects, so decoded
    /// keys can still drive components that speak raw terminal input.
    var rawInput: String? {
        switch self {
        case .enter: return "\r"
        case .newline: return "\n"
        case .backspace: return "\u{7F}"
        case .delete: return "\u{1B}[3~"
        case .tab: return "\u{09}"
        case .backTab: return "\u{1B}[Z"
        case .escape: return "\u{1B}"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .home: return "\u{1B}[H"
        case .end: return "\u{1B}[F"
        case .pageUp: return "\u{1B}[5~"
        case .pageDown: return "\u{1B}[6~"
        case .text(let value): return value
        case .interrupt, .endOfTransmission, .paste, .unhandled: return nil
        }
    }
}
