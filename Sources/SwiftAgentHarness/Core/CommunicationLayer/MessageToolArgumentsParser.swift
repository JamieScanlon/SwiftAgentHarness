import Foundation

/// Incrementally extracts visible text from streaming `message` tool JSON arguments.
public enum MessageToolArgumentsParser {
    public static let toolName = "message"

    /// Best-effort visible text from a partial or complete JSON arguments payload.
    public static func visibleText(fromArgumentsFragment fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        if let presentation = decodePresentation(from: fragment) {
            let fallback = presentation.textFallback()
            return fallback.isEmpty ? nil : fallback
        }
        return extractStreamingTextHeuristic(from: fragment)
    }

    public static func decodePresentation(from argumentsJSON: String) -> MessagePresentation? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MessagePresentation.self, from: data)
    }

    private static func extractStreamingTextHeuristic(from fragment: String) -> String? {
        var parts: [String] = []
        if let title = firstMatch(in: fragment, pattern: #""title"\s*:\s*"((?:\\.|[^"\\])*)""#) {
            parts.append(unescapeJSONString(title))
        }
        let textPattern = #""type"\s*:\s*"text"\s*,\s*"text"\s*:\s*"((?:\\.|[^"\\])*)""#
        for match in allMatches(in: fragment, pattern: textPattern) {
            let value = unescapeJSONString(match)
            if !value.isEmpty {
                parts.append(value)
            }
        }
        let bareTextPattern = #""text"\s*:\s*"((?:\\.|[^"\\])*)""#
        if parts.isEmpty, let match = firstMatch(in: fragment, pattern: bareTextPattern) {
            parts.append(unescapeJSONString(match))
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[capture])
        }
    }

    private static func unescapeJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
