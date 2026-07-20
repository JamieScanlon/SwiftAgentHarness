import EasyJSON
import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

/// CR-E: rung 2 of the compaction cost ladder is a deterministic, LLM-free 1-line tool-result
/// summary. These tests pin the per-tool output shapes and assert the summarizer is pure
/// synchronous string logic (no async, no model/provider wiring).
@Suite("DeterministicToolResultSummary")
struct DeterministicToolResultSummaryTests {
    private func call(_ name: String, _ args: [String: JSON] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: .object(args), id: "tc-1")
    }

    private func result(_ content: String, success: Bool = true) -> ToolResult {
        ToolResult(success: success, content: content, metadata: .object([:]), toolCallId: "tc-1")
    }

    @Test("terminal summary reports command, exit, and line count")
    func bashShape() {
        let line = DeterministicToolResultSummary.line(
            for: call("bash", ["command": .string("npm test")]),
            result: result("line1\nline2\nline3")
        )
        #expect(line == "[terminal] ran `npm test` -> exit 0, 3 lines output")
    }

    @Test("terminal summary reports non-zero exit on failure")
    func bashNonZeroExit() {
        let line = DeterministicToolResultSummary.line(
            for: call("terminal", ["command": .string("false")]),
            result: result("", success: false)
        )
        #expect(line == "[terminal] ran `false` -> non-zero exit, 1 lines output")
    }

    @Test("read_file summary reports path and char count")
    func readFileShape() {
        let line = DeterministicToolResultSummary.line(
            for: call("read_file", ["path": .string("config.py")]),
            result: result(String(repeating: "x", count: 1_200))
        )
        #expect(line == "[read_file] read config.py (1200 chars)")
    }

    @Test("read_attachment summary reports attachment id and char count")
    func readAttachmentShape() {
        let attachmentID = UUID()
        let line = DeterministicToolResultSummary.line(
            for: call("read_attachment", ["attachment_id": .string(attachmentID.uuidString)]),
            result: result("hello")
        )
        #expect(line == "[read_attachment] read \(attachmentID.uuidString) (5 chars)")
    }

    @Test("grep summary reports pattern and match count")
    func grepShape() {
        let line = DeterministicToolResultSummary.line(
            for: call("grep", ["pattern": .string("compress")]),
            result: result("m1\nm2\nm3\nm4\nm5\nm6\nm7\nm8\nm9\nm10\nm11\nm12")
        )
        #expect(line == "[search_files] content search for 'compress' -> 12 matches")
    }

    @Test("web_search summary reports query and char count")
    func webSearchShape() {
        let line = DeterministicToolResultSummary.line(
            for: call("web_search", ["query": .string("context compaction")]),
            result: result(String(repeating: "y", count: 3_412))
        )
        #expect(line == "[web_search] query='context compaction' (3412 chars result)")
    }

    @Test("unknown tool falls back to generic char-count line")
    func unknownToolFallback() {
        let line = DeterministicToolResultSummary.line(
            for: call("mystery_tool"),
            result: result("abcde")
        )
        #expect(line == "[mystery_tool] result (5 chars)")
    }

    @Test("summarizer is pure synchronous string logic callable without any LLM/provider wiring")
    func pureSynchronous() {
        // No async, no provider; a value is produced inline from inputs alone.
        let line = DeterministicToolResultSummary.line(
            for: call("read_file", ["path": .string("a.txt")]),
            result: result("hello")
        )
        #expect(line == "[read_file] read a.txt (5 chars)")
    }
}
