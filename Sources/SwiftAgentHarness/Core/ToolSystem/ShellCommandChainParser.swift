import Foundation

/// Splits shell command strings into top-level segments separated by `&&`, `|`, `;`, or newlines.
enum ShellCommandChainParser {
    static func segments(in command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var index = command.startIndex

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
            current = ""
        }

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                index = command.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == "\n" || character == ";" {
                flush()
                index = command.index(after: index)
                continue
            }
            if character == "|" {
                flush()
                index = command.index(after: index)
                continue
            }
            if character == "&" {
                let next = command.index(after: index)
                if next < command.endIndex, command[next] == "&" {
                    flush()
                    index = command.index(after: next)
                    continue
                }
            }
            current.append(character)
            index = command.index(after: index)
        }
        flush()
        return segments
    }
}
