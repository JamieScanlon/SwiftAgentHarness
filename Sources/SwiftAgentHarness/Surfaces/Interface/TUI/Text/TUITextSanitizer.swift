import Foundation

/// Strips terminal control sequences from text that did not originate in the renderer.
///
/// Anything that reaches a frame from outside the surface — pasted content, model
/// output, tool results — is untrusted with respect to the terminal: a raw escape in
/// that text is *executed* by the emulator, and because ``ANSIWidth`` correctly measures
/// escapes as zero-width, an injected sequence sails past the width invariant that would
/// otherwise catch it. Sanitize at the point content enters the surface.
public enum TUITextSanitizer: Sendable {
    /// Collapses CRLF and lone CR to LF.
    ///
    /// Needed anywhere text is split on `"\n"`: Swift merges CR+LF into a single extended
    /// grapheme cluster, so neither `split(separator: "\n")` nor a `Character` comparison
    /// against `"\r"` or `"\n"` matches it, and the cluster survives into a rendered line
    /// measuring zero columns — invisible to the width invariant, and a real line break
    /// on the actual terminal.
    public static func normalizedNewlines(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Removes escape sequences and C0/C1 controls, preserving newlines and tabs.
    public static func sanitizeMultiline(_ text: String) -> String {
        sanitize(text, allowNewlines: true)
    }

    /// Removes escape sequences and all control characters including newlines.
    public static func sanitizeSingleLine(_ text: String) -> String {
        sanitize(text, allowNewlines: false)
    }

    private static func sanitize(_ text: String, allowNewlines: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1B}" {
                index = ANSIWidth.skipEscape(in: text, from: index)
                continue
            }
            if character == "\r\n" {
                // One grapheme cluster, not two characters.
                if allowNewlines { result.append("\n") }
                index = text.index(after: index)
                continue
            }
            if character == "\r" {
                // Terminals deliver pasted line breaks as CR; normalize so downstream
                // line accounting sees the same separator regardless of emulator.
                if allowNewlines {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" {
                        index = next
                        continue
                    }
                    result.append("\n")
                }
                index = text.index(after: index)
                continue
            }
            if character == "\n" {
                if allowNewlines { result.append("\n") }
                index = text.index(after: index)
                continue
            }
            if character == "\t" {
                result.append("\t")
                index = text.index(after: index)
                continue
            }
            if isControl(character) {
                index = text.index(after: index)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func isControl(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
    }
}
