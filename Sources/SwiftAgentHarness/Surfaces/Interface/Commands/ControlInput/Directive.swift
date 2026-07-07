import Foundation

/// Turn-tuning tokens stripped before the model sees inbound content.
public enum DirectiveKind: String, Sendable, Equatable, CaseIterable {
    case think
    case model
    case verbose
    case reasoning
    case elevated
    case queue
}

public enum DirectiveScope: String, Sendable, Equatable {
    case inlineHint
    case sessionSetting
}

public enum DirectiveValue: Sendable, Equatable {
    case thinkingLevel(ThinkingLevel)
    case modelSlug(String)
    case flag
}

public struct AppliedDirective: Sendable, Equatable {
    public var kind: DirectiveKind
    public var value: DirectiveValue?
    public var scope: DirectiveScope

    public init(kind: DirectiveKind, value: DirectiveValue? = nil, scope: DirectiveScope) {
        self.kind = kind
        self.value = value
        self.scope = scope
    }

    public var thinkingConfig: ThinkingConfig? {
        switch (kind, value) {
        case (.think, .thinkingLevel(let level)), (.reasoning, .thinkingLevel(let level)):
            return level == .off ? .disabled : .level(level, budgetTokens: nil)
        case (.think, .none), (.reasoning, .none):
            return nil
        default:
            return nil
        }
    }

    public var modelSlug: String? {
        guard kind == .model, case .modelSlug(let slug)? = value else { return nil }
        return slug
    }
}

public enum DirectiveCatalog {
    public static let directiveNames: Set<String> = Set(DirectiveKind.allCases.map(\.rawValue))

    public static func isDirective(_ name: String) -> Bool {
        directiveNames.contains(normalize(name))
    }

    public static func normalize(_ name: String) -> String {
        var token = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.hasPrefix("/") { token.removeFirst() }
        return token
    }

    /// Parses one directive token and any inline value, returning consumed length in the source string.
    public static func parseToken(from input: String) -> (directive: AppliedDirective, consumed: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = trimmed.dropFirst()
        guard !body.isEmpty else { return nil }

        let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == ":" }) ?? body.endIndex
        let rawName = String(body[..<nameEnd]).lowercased()
        guard let kind = DirectiveKind(rawValue: rawName) else { return nil }

        var remainder = String(body[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix(":") {
            remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch kind {
        case .verbose, .elevated, .queue:
            let consumedPrefix = trimmed.prefix(while: { $0 != "\n" })
            return (AppliedDirective(kind: kind, value: .flag, scope: .inlineHint), String(consumedPrefix))
        case .think, .reasoning:
            return parseLevelDirective(kind: kind, remainder: remainder, trimmed: trimmed, rawName: rawName)
        case .model:
            return parseModelDirective(remainder: remainder, trimmed: trimmed, rawName: rawName)
        }
    }

    private static func parseLevelDirective(
        kind: DirectiveKind,
        remainder: String,
        trimmed: String,
        rawName: String
    ) -> (AppliedDirective, String)? {
        guard !remainder.isEmpty else {
            let consumed = "/\(rawName)"
            return (AppliedDirective(kind: kind, value: nil, scope: .inlineHint), consumed)
        }
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let levelToken = String(parts[0]).lowercased()
        guard let level = ThinkingLevel(rawValue: levelToken) else {
            return nil
        }
        let consumed: String
        if parts.count > 1 {
            consumed = "/\(rawName) \(levelToken)"
        } else {
            consumed = "/\(rawName) \(levelToken)"
        }
        return (AppliedDirective(kind: kind, value: .thinkingLevel(level), scope: .inlineHint), consumed)
    }

    private static func parseModelDirective(
        remainder: String,
        trimmed: String,
        rawName: String
    ) -> (AppliedDirective, String)? {
        guard !remainder.isEmpty else {
            return (AppliedDirective(kind: .model, value: nil, scope: .inlineHint), "/\(rawName)")
        }
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let slug = String(parts[0])
        let consumed = parts.count > 1 ? "/\(rawName) \(slug)" : "/\(rawName) \(slug)"
        return (AppliedDirective(kind: .model, value: .modelSlug(slug), scope: .inlineHint), consumed)
    }

    public static func acknowledgement(for directives: [AppliedDirective]) -> String {
        directives.map { directive in
            switch directive.kind {
            case .think, .reasoning:
                if let level = directive.thinkingConfig {
                    return "Thinking set to \(describeThinking(level))."
                }
                return "Thinking directive acknowledged."
            case .model:
                if let slug = directive.modelSlug {
                    return "Model set to `\(slug)`."
                }
                return "Model directive acknowledged."
            case .verbose:
                return "Verbose mode toggled."
            case .elevated:
                return "Elevated execution toggled."
            case .queue:
                return "Queue directive acknowledged."
            }
        }.joined(separator: " ")
    }

    private static func describeThinking(_ config: ThinkingConfig) -> String {
        switch config {
        case .disabled: return "off"
        case .adaptive: return "adaptive"
        case .level(let level, _): return level.rawValue
        }
    }
}
