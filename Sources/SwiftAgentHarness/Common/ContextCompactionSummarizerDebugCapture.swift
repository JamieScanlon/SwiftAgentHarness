import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Writes optional debug artifacts for the context-compaction summarizer LLM: a time-stamped folder under
/// a configurable base path, containing `summarizer-input.md` (instruction, middle, handoff prompt) and
/// `summarizer-output.md` (raw model text).
enum ContextCompactionSummarizerDebugCapture: Sendable {
    private static let inputFileName = "summarizer-input.md"
    private static let outputFileName = "summarizer-output.md"

    /// Creates `{basePath}/{yyyy-MM-dd'T'HH-mm-ss.SSS'Z'}/` and returns it, or nil on failure.
    static func makeRunDirectory(basePath: String, logger: Logger?) -> URL? {
        let expanded = (basePath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            logger?.warning("[ContextCompactionSummarizerDebug] empty path after expansion")
            return nil
        }
        let base = URL(fileURLWithPath: expanded, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        let folderName = formatter.string(from: Date())
        let run = base.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: nil)
            return run
        } catch {
            logger?.warning("[ContextCompactionSummarizerDebug] could not create \(run.path): \(String(describing: error))")
            return nil
        }
    }

    static func writeInput(
        directory: URL,
        model: String,
        maxMessages: Int,
        systemInstruction: String,
        middleMessages: [Message],
        handoffUserContent: String
    ) throws {
        var body = """
        # Context compaction summarizer — input

        This file mirrors what is sent to the compaction LLM, in order:

        1. **System instruction** (below) — same as the request’s system `Message`.
        2. **Middle messages** (below) — the **post-pruning** middle segment: same `Message` array as in code after `ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(…)` (not the raw transcript middle). The live request is `system` + this middle + final handoff `user` message.
        3. **User handoff prompt** (below) — same rendered template as the last `user` `Message` in the request (after **2**).

        - **Model**: \(model)
        - **maxMessages (cap on synthesized middle)**: \(maxMessages)

        ## System instruction

        \(systemInstruction)

        ## Middle messages (post-pruning; exact payload segment sent to the LLM before the handoff user turn)

        """
        for (i, m) in middleMessages.enumerated() {
            body += "### [\(i)] \(Self.messageHeaderMetadata(m))\n\n"
            if m.role == .assistant, !m.toolCalls.isEmpty {
                body += "#### Tool calls (assistant request)\n\n"
                body += Self.markdownForToolCalls(m.toolCalls)
            }
            body += "\(m.content)\n\n"
        }
        body += """
        ## User handoff prompt (rendered template)

        \(handoffUserContent)
        """
        let url = directory.appendingPathComponent(inputFileName, isDirectory: false)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeOutput(directory: URL, rawResponse: String) throws {
        let body = """
        # Context compaction summarizer — raw LLM output

        The text below is the model response as returned to the server (before `<summary>` extraction).

        ---

        \(rawResponse)
        """
        let url = directory.appendingPathComponent(outputFileName, isDirectory: false)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Message serialization for debug markdown

    private static func messageHeaderMetadata(_ m: Message) -> String {
        var parts: [String] = [
            "id=\(m.id.uuidString)",
            "role=\(m.role.rawValue)",
        ]
        if m.role == .tool {
            if let tid = m.toolCallId, !tid.isEmpty {
                parts.append("toolCallId=\(tid)")
            } else {
                parts.append("toolCallId=(none)")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func markdownForToolCalls(_ toolCalls: [ToolCall]) -> String {
        var s = ""
        for (j, tc) in toolCalls.enumerated() {
            let n = j + 1
            let idStr: String
            if let id = tc.id, !id.isEmpty {
                idStr = id
            } else {
                idStr = "(none)"
            }
            s += "- **#\(n)** — `id` = `\(idStr)` — **name** = `\(tc.name)`\n"
            s += "  - **arguments** (JSON):\n\n"
            s += "```json\n\(Self.prettyJSONString(tc.arguments))\n```\n"
            if let inst = tc.instructions, !inst.isEmpty {
                s += "  - **instructions**:\n\n\(inst)\n\n"
            }
        }
        if !s.isEmpty { s += "\n" }
        return s
    }

    /// Pretty JSON for `ToolCall.arguments` (matches patterns in `ToolMessage` / `LMStudioLLM`).
    private static func prettyJSONString(_ json: JSON) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(json), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: json)
    }
}
