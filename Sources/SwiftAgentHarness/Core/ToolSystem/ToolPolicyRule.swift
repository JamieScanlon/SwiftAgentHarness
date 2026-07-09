import Foundation

/// Parsed representation of one tool policy token from allow/deny lists or durable grants.
public enum ToolPolicyRule: Sendable, Equatable, Hashable, Codable {
    case wildcard
    case bareName(String)
    case nameGlob(String)
    case groupAlias(String)
    case argumentMatcher(toolName: String, pattern: String)

    /// Whether this rule participates in availability (name-level) matching.
    var isNameLevelRule: Bool {
        switch self {
        case .wildcard, .bareName, .nameGlob, .groupAlias:
            return true
        case .argumentMatcher:
            return false
        }
    }

    /// Canonical tool name when this rule refers to a single tool (not glob/group).
    var canonicalToolName: String? {
        switch self {
        case .bareName(let name):
            return name
        case .argumentMatcher(let toolName, _):
            return toolName
        case .wildcard, .nameGlob, .groupAlias:
            return nil
        }
    }

    /// Original config token form for display and persistence.
    public var rawToken: String {
        switch self {
        case .wildcard:
            return "*"
        case .bareName(let name):
            return name
        case .nameGlob(let pattern):
            return pattern
        case .groupAlias(let id):
            return "group:\(id)"
        case .argumentMatcher(let toolName, let pattern):
            let escaped = pattern.replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            return "\(toolName)(\(escaped))"
        }
    }
}

enum ToolPolicyRuleParseError: Error, Equatable {
    case emptyToken
    case malformedArgumentMatcher(String)
}

enum ToolPolicyRuleParser {
    static func parse(_ raw: String) throws -> ToolPolicyRule {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolPolicyRuleParseError.emptyToken }

        if trimmed == "*" {
            return .wildcard
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("group:") {
            let groupID = String(trimmed.dropFirst("group:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !groupID.isEmpty else {
                throw ToolPolicyRuleParseError.malformedArgumentMatcher(trimmed)
            }
            return .groupAlias(groupID)
        }

        if trimmed.hasPrefix("(") {
            throw ToolPolicyRuleParseError.malformedArgumentMatcher(trimmed)
        }

        if let matcher = parseArgumentMatcher(trimmed) {
            return matcher
        }

        if trimmed.contains("(") {
            throw ToolPolicyRuleParseError.malformedArgumentMatcher(trimmed)
        }

        if trimmed.contains("*") || trimmed.contains("?") {
            return .nameGlob(trimmed)
        }

        return .bareName(ToolNamePolicyNormalization.canonical(trimmed))
    }

    static func parseMany(_ rawTokens: [String]) throws -> [ToolPolicyRule] {
        if rawTokens.contains(where: { ToolNamePolicyNormalization.normalizeToken($0) == "*" }) {
            return [.wildcard]
        }
        var seen = Set<ToolPolicyRule>()
        var rules: [ToolPolicyRule] = []
        for raw in rawTokens {
            let rule = try parse(raw)
            if seen.insert(rule).inserted {
                rules.append(rule)
            }
        }
        return rules.sorted { $0.rawToken < $1.rawToken }
    }

    private static func parseArgumentMatcher(_ trimmed: String) -> ToolPolicyRule? {
        guard let openIndex = trimmed.firstIndex(of: "(") else {
            return nil
        }
        let toolPart = String(trimmed[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolPart.isEmpty else { return nil }

        let patternStart = trimmed.index(after: openIndex)
        guard patternStart < trimmed.endIndex else { return nil }

        var depth = 1
        var index = patternStart
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "\\" {
                let next = trimmed.index(after: index)
                guard next < trimmed.endIndex else { return nil }
                index = trimmed.index(after: next)
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let patternBody = String(trimmed[patternStart..<index])
                    let afterClose = trimmed.index(after: index)
                    guard afterClose == trimmed.endIndex else { return nil }
                    let pattern = unescapePattern(patternBody)
                    let toolName = ToolNamePolicyNormalization.canonical(toolPart)
                    return .argumentMatcher(toolName: toolName, pattern: pattern)
                }
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private static func unescapePattern(_ body: String) -> String {
        var result = ""
        var index = body.startIndex
        while index < body.endIndex {
            let char = body[index]
            if char == "\\" {
                let next = body.index(after: index)
                if next < body.endIndex {
                    result.append(body[next])
                    index = body.index(after: next)
                    continue
                }
            }
            result.append(char)
            index = body.index(after: index)
        }
        return result
    }
}
