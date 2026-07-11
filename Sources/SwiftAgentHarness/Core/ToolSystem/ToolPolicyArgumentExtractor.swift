import EasyJSON
import Foundation

enum ToolPolicyArgumentExtractor {
    static func extractedValues(
        toolName: String,
        arguments: JSON
    ) -> [String] {
        let canonical = ToolNamePolicyNormalization.canonical(toolName)
        switch canonical {
        case "bash":
            guard let command = stringValue(arguments, keys: ["command"]) else { return [] }
            return ShellCommandChainParser.segments(in: command)
        case "read_file", "write_file", "edit":
            if let path = stringValue(arguments, keys: ["path", "file_path", "filePath"]) {
                return [canonicalizePath(path)]
            }
            return []
        case "read_attachment":
            if let attachmentID = stringValue(arguments, keys: ["attachment_id"]) {
                return [attachmentID]
            }
            return []
        case "web_fetch":
            if let url = stringValue(arguments, keys: ["url"]) {
                return [normalizeURL(url)]
            }
            return []
        default:
            return firstStringProperty(in: arguments).map { [$0] } ?? []
        }
    }

    static func stringValue(_ arguments: JSON, keys: [String]) -> String? {
        guard case .object(let fields) = arguments else { return nil }
        for key in keys {
            guard let value = fields[key] else { continue }
            if case .string(let text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstStringProperty(in arguments: JSON) -> String? {
        guard case .object(let fields) = arguments else { return nil }
        for (_, value) in fields {
            if case .string(let text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func canonicalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let url = URL(fileURLWithPath: trimmed)
        let standardized = url.standardizedFileURL.path
        return (standardized as NSString).standardizingPath
    }

    static func normalizeURL(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func patternContainsTraversal(_ pattern: String) -> Bool {
        pattern.contains("..")
    }
}
