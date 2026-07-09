import EasyJSON
import Foundation
import SwiftAgentKit

struct ToolCallCapability: Sendable, Equatable {
    let isReadOnly: Bool
    let isConcurrencySafe: Bool
}

/// Input-dependent capability predicates for polymorphic tools (bash-style exec, process poll vs kill).
/// Fail-closed: unparseable input or unknown commands are treated as mutating / not concurrency-safe.
enum ToolCallCapabilityClassifier {
    static let polymorphicToolNames: Set<String> = ["bash", "process"]

    static func isPolymorphic(_ toolName: String) -> Bool {
        polymorphicToolNames.contains(ToolNamePolicyNormalization.canonical(toolName))
    }

    static func classify(toolName: String, arguments: JSON) -> ToolCallCapability {
        let canonical = ToolNamePolicyNormalization.canonical(toolName)
        switch canonical {
        case "bash":
            return classifyBash(arguments: arguments)
        case "process":
            return classifyProcess(arguments: arguments)
        default:
            return mutatingCapability
        }
    }

    static func parallelSafety(for toolName: String, arguments: JSON) -> ToolParallelSafety {
        let capability = classify(toolName: toolName, arguments: arguments)
        if capability.isConcurrencySafe {
            return .parallelSafe
        }
        return .mutating
    }

    static func callIsReadOnly(entry: ToolRegistryEntry, arguments: JSON) -> Bool {
        if isPolymorphic(entry.name) {
            return classify(toolName: entry.name, arguments: arguments).isReadOnly
        }
        return entry.effectClass == .readOnly
    }

    private static func classifyBash(arguments: JSON) -> ToolCallCapability {
        guard let command = ToolPolicyArgumentExtractor.stringValue(arguments, keys: ["command"]) else {
            return mutatingCapability
        }
        let segments = ShellCommandChainParser.segments(in: command)
        guard !segments.isEmpty else { return mutatingCapability }
        let allReadOnly = segments.allSatisfy(isReadOnlyBashSegment(_:))
        return allReadOnly ? readOnlyParallelSafeCapability : mutatingCapability
    }

    private static func classifyProcess(arguments: JSON) -> ToolCallCapability {
        let action = ToolPolicyArgumentExtractor.stringValue(arguments, keys: ["action"]) ?? "poll"
        switch action.lowercased() {
        case "poll":
            return readOnlyParallelSafeCapability
        case "kill", "send_keys":
            return mutatingCapability
        default:
            return mutatingCapability
        }
    }

    private static func isReadOnlyBashSegment(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsWriteRedirect(trimmed) { return false }

        let tokens = tokenizeShellSegment(trimmed)
        guard let commandToken = tokens.first else { return false }

        if commandToken == "git" {
            return isReadOnlyGitInvocation(tokens)
        }

        let commandName = basenameOfCommandToken(commandToken)
        return readOnlyCommandNames.contains(commandName)
    }

    private static func containsWriteRedirect(_ segment: String) -> Bool {
        var quote: Character?
        var index = segment.startIndex
        while index < segment.endIndex {
            let character = segment[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index = segment.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = segment.index(after: index)
                continue
            }
            if character == ">" {
                let next = segment.index(after: index)
                if next < segment.endIndex, segment[next] == ">" {
                    return true
                }
                return true
            }
            index = segment.index(after: index)
        }
        return false
    }

    private static func tokenizeShellSegment(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var index = segment.startIndex

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tokens.append(trimmed)
            }
            current = ""
        }

        while index < segment.endIndex {
            let character = segment[index]
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                index = segment.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index = segment.index(after: index)
                continue
            }
            if character.isWhitespace {
                flush()
                index = segment.index(after: index)
                continue
            }
            current.append(character)
            index = segment.index(after: index)
        }
        flush()
        return tokens
    }

    private static func basenameOfCommandToken(_ token: String) -> String {
        let unquoted: String
        if (token.hasPrefix("'") && token.hasSuffix("'")) || (token.hasPrefix("\"") && token.hasSuffix("\"")) {
            unquoted = String(token.dropFirst().dropLast())
        } else {
            unquoted = token
        }
        let url = URL(fileURLWithPath: unquoted)
        return url.lastPathComponent.lowercased()
    }

    private static func isReadOnlyGitInvocation(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        let subcommand = tokens[1].lowercased()
        return readOnlyGitSubcommands.contains(subcommand)
    }

    /// Conservative read-only command allowlist. Unknown commands fail closed (mutating).
    private static let readOnlyCommandNames: Set<String> = [
        "cat", "du", "echo", "find", "grep", "head", "ls", "pwd", "rg", "stat", "tail", "test", "true", "false", "wc", "which", "file", "id", "uname", "date", "env", "printenv",
    ]

    private static let readOnlyGitSubcommands: Set<String> = [
        "diff", "log", "show", "status",
    ]

    private static let readOnlyParallelSafeCapability = ToolCallCapability(isReadOnly: true, isConcurrencySafe: true)
    private static let mutatingCapability = ToolCallCapability(isReadOnly: false, isConcurrencySafe: false)
}
