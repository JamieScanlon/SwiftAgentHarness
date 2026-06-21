import Foundation
import SwiftAgentKit

enum ContextCompactionReinjectionCollector: Sendable {
    static func collectMessages(
        head: [Message],
        middle: [Message],
        tail: [Message],
        config: ContextCompactionConfiguration
    ) -> [Message] {
        guard config.compactionReinjectionEnabled else { return [] }
        var out: [Message] = []
        if let planLine = planPresenceLine(head: head, middle: middle, tail: tail) {
            out.append(planLine)
        }
        let filePaths = recentFilePaths(head: head, middle: middle, tail: tail, maxCount: 5)
        if !filePaths.isEmpty {
            let rendered = filePaths.enumerated().map { idx, path in
                "\(idx + 1). \(path)"
            }.joined(separator: "\n")
            out.append(
                Message(
                    id: UUID(),
                    role: .system,
                    content: """
[Context reinjection — recent files]
The following paths were recently accessed. Re-read with tools if exact content is needed:
\(rendered)
""",
                    timestamp: Date(),
                    toolCalls: []
                )
            )
        }
        return out
    }

    private static func planPresenceLine(head: [Message], middle: [Message], tail: [Message]) -> Message? {
        let combined = (head + middle + tail).map(\.content).joined(separator: "\n").lowercased()
        guard combined.contains("plan.md") || combined.contains("create_plan") || combined.contains("get_plan") else {
            return nil
        }
        return Message(
            id: UUID(),
            role: .system,
            content: "[Context reinjection] A plan.md is active for this conversation; use get_plan before large changes.",
            timestamp: Date(),
            toolCalls: []
        )
    }

    private static func recentFilePaths(
        head: [Message],
        middle: [Message],
        tail: [Message],
        maxCount: Int
    ) -> [String] {
        let pattern = #"(?i)(?:read_file|read|write_file|edit_file|glob|grep)[^\n]*?(?:path|file)[^\n]*?["']([^"']+)["']"#
        var paths: [String] = []
        var seen: Set<String> = []
        for message in (head + middle + tail).reversed() {
            let content = message.content
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in regex.matches(in: content, range: range) {
                guard match.numberOfRanges > 1,
                      let swiftRange = Range(match.range(at: 1), in: content)
                else { continue }
                let path = String(content[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, !seen.contains(path) else { continue }
                seen.insert(path)
                paths.append(path)
                if paths.count >= maxCount { return paths }
            }
            if paths.count >= maxCount { break }
        }
        return paths
    }
}
