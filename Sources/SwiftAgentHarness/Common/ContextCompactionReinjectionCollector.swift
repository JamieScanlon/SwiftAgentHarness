import EasyJSON
import Foundation
import SwiftAgentKit

enum ContextCompactionReinjectionCollector: Sendable {
    /// Tool names whose calls reference a file path (used to attribute recent file accesses).
    private static let fileToolNames: Set<String> = [
        "read_file", "read", "write_file", "edit_file", "glob", "grep",
    ]

    static func collectMessages(
        head: [Message],
        middle: [Message],
        tail: [Message],
        skills: [ReinjectableSkill],
        config: ContextCompactionConfiguration
    ) -> [Message] {
        guard config.compactionReinjectionEnabled else { return [] }
        var out: [Message] = []
        if let planLine = planPresenceLine(head: head, middle: middle, tail: tail) {
            out.append(planLine)
        }
        if let asyncLine = asyncTaskStatusLine(head: head, middle: middle, tail: tail) {
            out.append(asyncLine)
        }
        out.append(contentsOf: fileReinjectionMessages(head: head, middle: middle, tail: tail, config: config))
        out.append(contentsOf: skillReinjectionMessages(skills: skills, config: config))
        return out
    }

    // MARK: - File re-injection

    private static func fileReinjectionMessages(
        head: [Message],
        middle: [Message],
        tail: [Message],
        config: ContextCompactionConfiguration
    ) -> [Message] {
        let maxCount = max(0, config.reinjectionRecentFileCount)
        guard maxCount > 0 else { return [] }

        guard config.reinjectFileContentEnabled else {
            return pathOnlyListMessages(head: head, middle: middle, tail: tail, maxCount: maxCount)
        }

        let recentFiles = recentFileContents(head: head, middle: middle, tail: tail, maxCount: maxCount)
        guard !recentFiles.isEmpty else { return [] }

        let cpt = max(1.0, config.charactersPerToken)
        let perFileCharBudget = max(0, config.reinjectionPerFileTokenBudget) * Int(cpt.rounded())
        let totalTokenBudget = max(0, config.reinjectionTotalFileTokenBudget)

        var out: [Message] = []
        var tokensUsed = 0
        for file in recentFiles {
            guard let content = file.content else {
                out.append(filePathOnlyLine(path: file.path))
                continue
            }
            let capped = truncateToCharBudget(content, maxCharacters: perFileCharBudget, marker: fileTruncationMarker)
            let cappedTokens = estimatedTokens(capped, charactersPerToken: cpt)
            if tokensUsed + cappedTokens > totalTokenBudget {
                break
            }
            tokensUsed += cappedTokens
            out.append(fileContentAttachment(path: file.path, content: capped))
        }
        return out
    }

    private static func fileContentAttachment(path: String, content: String) -> Message {
        Message(
            id: UUID(),
            role: .system,
            content: """
[Context reinjection — recent file content]
\(path):
\(content)
""",
            timestamp: Date(),
            toolCalls: []
        )
    }

    private static func filePathOnlyLine(path: String) -> Message {
        Message(
            id: UUID(),
            role: .system,
            content: """
[Context reinjection — recent file]
\(path) was recently accessed but its content is unavailable; re-read with tools if needed.
""",
            timestamp: Date(),
            toolCalls: []
        )
    }

    /// Original path-only behavior: a single numbered list of recent file paths.
    private static func pathOnlyListMessages(
        head: [Message],
        middle: [Message],
        tail: [Message],
        maxCount: Int
    ) -> [Message] {
        let filePaths = recentFilePaths(head: head, middle: middle, tail: tail, maxCount: maxCount)
        guard !filePaths.isEmpty else { return [] }
        let rendered = filePaths.enumerated().map { idx, path in
            "\(idx + 1). \(path)"
        }.joined(separator: "\n")
        return [
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
            ),
        ]
    }

    // MARK: - Skill re-injection

    private static func skillReinjectionMessages(
        skills: [ReinjectableSkill],
        config: ContextCompactionConfiguration
    ) -> [Message] {
        guard !skills.isEmpty else { return [] }
        let cpt = max(1.0, config.charactersPerToken)
        let perSkillCharBudget = max(0, config.reinjectionPerSkillTokenBudget) * Int(cpt.rounded())
        let totalTokenBudget = max(0, config.reinjectionTotalSkillTokenBudget)

        var out: [Message] = []
        var tokensUsed = 0
        for skill in skills {
            let trimmed = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let capped = truncateToCharBudget(trimmed, maxCharacters: perSkillCharBudget, marker: skillTruncationMarker)
            let cappedTokens = estimatedTokens(capped, charactersPerToken: cpt)
            if tokensUsed + cappedTokens > totalTokenBudget {
                break
            }
            tokensUsed += cappedTokens
            out.append(skillContentAttachment(name: skill.name, content: capped))
        }
        return out
    }

    private static func skillContentAttachment(name: String, content: String) -> Message {
        Message(
            id: UUID(),
            role: .system,
            content: """
[Context reinjection — active skill: \(name)]
\(content)
""",
            timestamp: Date(),
            toolCalls: []
        )
    }

    // MARK: - Plan / async status

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

    /// Best-effort async/background-task status line, transcript-derived. Emits nothing when no
    /// background-task markers are present.
    private static func asyncTaskStatusLine(head: [Message], middle: [Message], tail: [Message]) -> Message? {
        let markers = ["schedule_task", "scheduled task", "background task", "async task", "invoke_sub_agent", "spawn_sub_agent"]
        let combined = (head + middle + tail).map(\.content).joined(separator: "\n").lowercased()
        guard markers.contains(where: { combined.contains($0) }) else { return nil }
        return Message(
            id: UUID(),
            role: .system,
            content: "[Context reinjection] Async/background tasks were tracked for this conversation; check their status before relying on their results.",
            timestamp: Date(),
            toolCalls: []
        )
    }

    // MARK: - Resolution helpers

    /// Ordered (most-recent first) recent files with their latest tool-result content when resolvable.
    /// Builds `toolCallId -> path` from assistant `toolCalls` (file tools with a `path`/`file_path`
    /// argument) and `toolCallId -> content` from `role == .tool` messages, then walks assistant
    /// tool calls newest-first to keep at most `maxCount` unique paths. No filesystem I/O.
    private static func recentFileContents(
        head: [Message],
        middle: [Message],
        tail: [Message],
        maxCount: Int
    ) -> [(path: String, content: String?)] {
        let all = head + middle + tail
        var idToContent: [String: String] = [:]
        for message in all where message.role == .tool {
            guard let id = message.toolCallId, !id.isEmpty else { continue }
            // Keep the most recent result per id (later messages overwrite earlier ones).
            idToContent[id] = message.content
        }

        var ordered: [(path: String, content: String?)] = []
        var seen: Set<String> = []
        for message in all.reversed() where message.role == .assistant {
            for toolCall in message.toolCalls where fileToolNames.contains(toolCall.name) {
                guard let path = firstStringArgument(toolCall, keys: ["path", "file_path"]),
                      !seen.contains(path)
                else { continue }
                seen.insert(path)
                let content = toolCall.id.flatMap { idToContent[$0] }
                ordered.append((path: path, content: content))
                if ordered.count >= maxCount { return ordered }
            }
        }
        return ordered
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

    private static func firstStringArgument(_ toolCall: ToolCall, keys: [String]) -> String? {
        guard case .object(let dict) = toolCall.arguments else { return nil }
        for key in keys {
            if case .string(let value)? = dict[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static let fileTruncationMarker = "\n[...file content truncated for context re-injection...]"
    private static let skillTruncationMarker = "\n[...skill content truncated for context re-injection...]"

    private static func estimatedTokens(_ text: String, charactersPerToken: Double) -> Int {
        Int(ceil(Double(text.count) / max(1.0, charactersPerToken)))
    }

    private static func truncateToCharBudget(_ content: String, maxCharacters: Int, marker: String) -> String {
        guard maxCharacters > 0, content.count > maxCharacters else { return content }
        let end = content.index(content.startIndex, offsetBy: maxCharacters)
        return String(content[content.startIndex..<end]) + marker
    }
}
