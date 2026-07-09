import Foundation

enum ReadFileWindowing {
    static let maxReadBytes = 256_000

    static let exceedsCapGuidance =
        "File exceeds \(maxReadBytes) bytes. Re-read with offset (1-based line) and limit (max lines)."

    static func utf8ByteCount(_ content: String) -> Int {
        content.utf8.count
    }

    static func requiresWindowing(content: String, offsetLine: Int?, limitLines: Int?) -> Bool {
        guard offsetLine == nil, limitLines == nil else { return false }
        return utf8ByteCount(content) > maxReadBytes
    }

    static func sliceLines(
        content: String,
        offsetLine: Int?,
        limitLines: Int?
    ) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return content }

        let startIndex: Int
        if let offsetLine, offsetLine > 0 {
            startIndex = min(lines.count, offsetLine - 1)
        } else {
            startIndex = 0
        }

        let endIndex: Int
        if let limitLines, limitLines > 0 {
            endIndex = min(lines.count, startIndex + limitLines)
        } else {
            endIndex = lines.count
        }

        guard startIndex < endIndex else { return "" }
        let selected = lines[startIndex..<endIndex].joined(separator: "\n")
        return enforceByteCap(selected)
    }

    static func enforceByteCap(_ content: String) -> String {
        guard utf8ByteCount(content) > maxReadBytes else { return content }
        var cutoff = maxReadBytes
        let data = Data(content.utf8)
        while cutoff > 0 {
            let prefix = data.prefix(cutoff)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
            cutoff -= 1
        }
        return ""
    }
}

enum SubAgentDelegateResultBounds {
    /// Matches default `ToolResultFormattingConfiguration.persistenceMaxBytes` backstop.
    static let defaultMaxBytes = 256_000

    static func boundContent(_ content: String, maxBytes: Int = defaultMaxBytes) -> String {
        guard maxBytes > 0 else { return content }
        let data = Data(content.utf8)
        guard data.count > maxBytes else { return content }
        var cutoff = maxBytes
        while cutoff > 0 {
            let prefix = data.prefix(cutoff)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return """
                \(decoded)
                [sub-agent result truncated at producer: exceeded \(maxBytes) bytes; persistence budget backstop applied]
                """
            }
            cutoff -= 1
        }
        return "[sub-agent result truncated at producer: exceeded \(maxBytes) bytes; persistence budget backstop applied]"
    }
}
