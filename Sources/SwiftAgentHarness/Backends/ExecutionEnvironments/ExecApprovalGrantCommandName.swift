import Foundation

/// Derives durable exec-approval grant keys from shell command strings.
enum ExecApprovalGrantCommandName {
    private static let shellInterpreters: Set<String> = [
        "bash", "sh", "zsh", "dash", "ksh", "fish",
    ]

    private static let prefixWrappers: Set<String> = [
        "xargs", "exec", "sudo", "nice", "timeout", "stdbuf", "ionice",
    ]

    /// Returns the command name used for durable grant storage and lookup.
    /// Interpreter/wrapper prefixes are peeled so `bash -lc 'ls'` keys on `ls`, not `bash`.
    /// Returns `nil` when no safe grant key can be derived (fail-closed for bare interpreters).
    static func durableGrantCommandName(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return durableGrantCommandName(fromTokenized: tokenize(trimmed))
    }

    /// First whitespace-delimited token without interpreter peeling (legacy helper).
    static func commandName(from command: String) -> String? {
        command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)
    }

    private static func durableGrantCommandName(fromTokenized tokens: [String]) -> String? {
        guard let first = tokens.first else { return nil }
        let base = basename(first)

        if shellInterpreters.contains(base) {
            return peelShell(tokens: tokens)
        }
        if base == "env" {
            return peelEnv(tokens: tokens)
        }
        if prefixWrappers.contains(base) {
            return peelPrefixWrapper(tokens: Array(tokens.dropFirst()))
        }
        return base.isEmpty ? nil : first
    }

    private static func peelShell(tokens: [String]) -> String? {
        guard tokens.count >= 2 else { return nil }
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                continue
            }
            if token == "-c" || token == "-lc" {
                index += 1
                guard index < tokens.count else { return nil }
                return firstGrantableToken(inScript: tokens[index])
            }
            if token.hasPrefix("-") {
                if token.dropFirst().contains("c") {
                    index += 1
                    guard index < tokens.count else { return nil }
                    return firstGrantableToken(inScript: tokens[index])
                }
                index += 1
                continue
            }
            return nil
        }
        return nil
    }

    private static func peelEnv(tokens: [String]) -> String? {
        guard tokens.count >= 2 else { return nil }
        for index in 1..<tokens.count {
            let token = tokens[index]
            if isEnvAssignment(token) { continue }
            let remainder = tokens[index...].joined(separator: " ")
            return durableGrantCommandName(from: remainder)
        }
        return nil
    }

    private static func peelPrefixWrapper(tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-") {
                let takesArgument = flagTakesSeparateArgument(token)
                index += 1
                if takesArgument, index < tokens.count, !tokens[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }
            if token.allSatisfy(\.isNumber) {
                index += 1
                continue
            }
            let remainder = tokens[index...].joined(separator: " ")
            return durableGrantCommandName(from: remainder)
        }
        return nil
    }

    private static func flagTakesSeparateArgument(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token != "--" else { return false }
        let body = String(token.dropFirst())
        guard let first = body.first else { return false }
        if body.count == 1, first.isLetter {
            return true
        }
        if first.isLetter, body.dropFirst().allSatisfy(\.isNumber) {
            return false
        }
        return body.allSatisfy { $0.isLetter }
    }

    private static func firstGrantableToken(inScript script: String) -> String? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsTopLevelCommandSeparator(in: trimmed) else { return nil }
        return durableGrantCommandName(fromTokenized: tokenize(trimmed))
    }

    private static func containsTopLevelCommandSeparator(in script: String) -> Bool {
        var quote: Character?
        var index = script.startIndex

        while index < script.endIndex {
            let character = script[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index = script.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = script.index(after: index)
                continue
            }
            if character == "\n" || character == ";" || character == "`" {
                return true
            }
            if character == "|" {
                return true
            }
            if character == "&" {
                let next = script.index(after: index)
                if next < script.endIndex, script[next] == "&" {
                    return true
                }
                index = script.index(after: index)
                continue
            }
            if character == "$" {
                let next = script.index(after: index)
                guard next < script.endIndex, script[next] == "(" else {
                    index = script.index(after: index)
                    continue
                }
                let afterOpen = script.index(after: next)
                if afterOpen < script.endIndex, script[afterOpen] == "(" {
                    guard let resumeIndex = skipArithmeticExpansion(in: script, from: afterOpen) else {
                        return true
                    }
                    index = resumeIndex
                    continue
                }
                return true
            }
            index = script.index(after: index)
        }
        return false
    }

    private static func skipArithmeticExpansion(in script: String, from afterSecondOpen: String.Index) -> String.Index? {
        var depth = 1
        var index = afterSecondOpen
        while index < script.endIndex {
            let character = script[index]
            if character == "(" {
                let next = script.index(after: index)
                if next < script.endIndex, script[next] == "(" {
                    depth += 1
                    index = script.index(after: next)
                    continue
                }
            } else if character == ")" {
                let next = script.index(after: index)
                if next < script.endIndex, script[next] == ")" {
                    depth -= 1
                    if depth == 0 {
                        return script.index(after: next)
                    }
                    index = script.index(after: next)
                    continue
                }
            }
            index = script.index(after: index)
        }
        return nil
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else {
            return false
        }
        let key = token[..<equalsIndex]
        return !key.isEmpty && key.allSatisfy(isEnvAssignmentKeyCharacter)
    }

    private static func isEnvAssignmentKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func basename(_ token: String) -> String {
        let url = URL(fileURLWithPath: token)
        let last = url.lastPathComponent
        return last.isEmpty ? token : last
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                index = command.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = command.index(after: index)
                continue
            }
            if character == " " || character == "\t" || character == "\n" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                index = command.index(after: index)
                continue
            }
            current.append(character)
            index = command.index(after: index)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
