import EasyJSON
import Foundation
import SwiftAgentKit

/// Deterministic, LLM-free 1-line tool-result summarizer (rung 2 of the compaction cost ladder).
///
/// Reconstructs the *intent* of a tool invocation from its `ToolCall` arguments and folds in the
/// small result-only signal (exit status, char count, line count, match count). This is pure
/// synchronous string logic: no async, no model, no provider wiring. It is used as a replacement
/// strategy for older tool results while building the compaction LLM payload, preserving the key
/// signal at zero cost instead of dropping content to a blank marker.
public enum DeterministicToolResultSummary {
    /// Builds a single-line, payload-free description for `toolCall` given its `result`.
    ///
    /// Branches per tool name (with harness-native aliases); unknown tools fall back to a generic
    /// `"[<tool>] result (<N> chars)"` line so the function is always defined.
    public static func line(for toolCall: ToolCall, result: ToolResult) -> String {
        let chars = result.content.count
        switch toolCall.name {
        case "bash", "terminal", "execute_command", "run_command":
            let cmd = string(toolCall, "command") ?? ""
            let lines = result.content.split(separator: "\n", omittingEmptySubsequences: false).count
            let exit = result.success ? "exit 0" : "non-zero exit"
            return "[terminal] ran `\(cmd)` -> \(exit), \(lines) lines output"
        case "read_file", "read":
            let path = string(toolCall, "path") ?? string(toolCall, "file_path") ?? "?"
            return "[read_file] read \(path) (\(chars) chars)"
        case "read_attachment":
            let attachmentID = string(toolCall, "attachment_id") ?? "?"
            return "[read_attachment] read \(attachmentID) (\(chars) chars)"
        case "grep", "search_files", "search":
            let query = string(toolCall, "pattern") ?? string(toolCall, "query") ?? ""
            let matches = result.content.split(separator: "\n", omittingEmptySubsequences: false).count
            return "[search_files] content search for '\(query)' -> \(matches) matches"
        case "web_search", "web-search":
            let query = string(toolCall, "query") ?? ""
            return "[web_search] query='\(query)' (\(chars) chars result)"
        case "web-fetch", "web_fetch", "fetch":
            let url = string(toolCall, "url") ?? string(toolCall, "uri") ?? "?"
            return "[web_fetch] fetched \(url) (\(chars) chars)"
        default:
            return "[\(toolCall.name)] result (\(chars) chars)"
        }
    }

    private static func string(_ call: ToolCall, _ key: String) -> String? {
        guard case .object(let dict) = call.arguments, let value = dict[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }
}
