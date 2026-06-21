import Foundation

/// Tag prefix for trigger messages. Messages starting with this are from
/// cron jobs, event-driven scripts, external agents, or automation (e.g. Zapier).
enum TriggerContentBuilder {

    /// The tag that prefixes trigger message content. First line format: `[trigger] key1=value1; key2=value2; ...`
    static let triggerTag = "[trigger]"

    /// Builds the full user-message content for a trigger: one line of `[trigger] key=value; ...` then `\n\n` then the body.
    /// - Parameters:
    ///   - messageBody: The actual message text (appears after the blank line).
    ///   - triggerMetadata: Optional key-value map from the client (e.g. name, type, source). Loosely structured; no fixed schema.
    ///   - serverKeys: Optional keys added by the server (e.g. `received_at` with ISO8601 timestamp). Merged with triggerMetadata; server keys can override if same key.
    /// - Returns: Full content string to store and send to the LLM: `[trigger] k=v; ...\n\n` + messageBody.
    ///
    /// Values in metadata and serverKeys are sanitized so that semicolons and newlines in values do not break the single-line format (replaced with space). For full control, keep values simple.
    static func buildFullContent(
        messageBody: String,
        triggerMetadata: [String: String]? = nil,
        serverKeys: [String: String]? = nil
    ) -> String {
        var allPairs: [String: String] = [:]
        if let triggerMetadata {
            for (k, v) in triggerMetadata {
                allPairs[k] = sanitizeValue(v)
            }
        }
        if let serverKeys {
            for (k, v) in serverKeys {
                allPairs[k] = sanitizeValue(v)
            }
        }
        let line = buildTriggerLine(pairs: allPairs)
        return line + "\n\n" + messageBody
    }

    /// Builds only the first line: `[trigger] key1=value1; key2=value2; ...`
    /// - Parameter pairs: Key-value map. Keys and values are sanitized for single-line use.
    /// - Returns: A single line (no newline at end).
    static func buildTriggerLine(pairs: [String: String]) -> String {
        guard !pairs.isEmpty else {
            return triggerTag
        }
        let segments = pairs.sorted(by: { $0.key < $1.key }).map { "\(sanitizeKey($0.key))=\($0.value)" }
        return triggerTag + " " + segments.joined(separator: "; ")
    }

    /// Sanitizes a value so it does not contain semicolons or newlines (replaced with space).
    /// Keeps the trigger line parseable when splitting on `;` and `\n`.
    private static func sanitizeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Sanitizes a key so it does not contain `=` (replaced with underscore).
    private static func sanitizeKey(_ key: String) -> String {
        key.replacingOccurrences(of: "=", with: "_")
    }

    /// Parses stored content that may start with `[trigger] key=value; ...`.
    /// - Parameter content: Full message content (possibly with trigger line).
    /// - Returns: If content starts with trigger tag: (metadata dictionary from first line, body after `\n\n`). Otherwise: (nil, full content).
    static func parse(content: String) -> (triggerMetadata: [String: String]?, messageBody: String) {
        let tag = triggerTag
        guard content.hasPrefix(tag) else {
            return (nil, content)
        }
        guard let firstNewline = content.firstIndex(of: "\n") else {
            let rest = String(content[content.index(content.startIndex, offsetBy: tag.count)...]).trimmingCharacters(in: .whitespaces)
            let meta = parseTriggerLine(rest)
            return (meta.isEmpty ? nil : meta, "")
        }
        let firstLine = String(content[content.index(content.startIndex, offsetBy: tag.count)..<firstNewline]).trimmingCharacters(in: .whitespaces)
        let meta = parseTriggerLine(firstLine)
        let afterFirstLine = content.index(after: firstNewline)
        guard afterFirstLine < content.endIndex, content[afterFirstLine] == "\n" else {
            let body = String(content[afterFirstLine...])
            return (meta.isEmpty ? nil : meta, body)
        }
        let bodyStart = content.index(after: afterFirstLine)
        let body = String(content[bodyStart...])
        return (meta.isEmpty ? nil : meta, body)
    }

    /// Parses a single line "key1=value1; key2=value2" into [String: String].
    private static func parseTriggerLine(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        let segments = line.split(separator: ";", omittingEmptySubsequences: false)
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
