import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolResultExternalContentMiddleware")
struct ToolResultExternalContentMiddlewareTests {
    private func result(
        content: String,
        success: Bool = true,
        metadata: JSON = .object(["kind": .string("raw")])
    ) -> ToolResult {
        ToolResult(success: success, content: content, metadata: metadata, toolCallId: "call-1")
    }

    @Test("applies envelope to external tool output")
    func appliesWrap() {
        let call = ToolCall(name: "web_fetch", arguments: .object([:]), id: "call-1")
        let input = result(content: "page body")
        let wrapped = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: input,
            entry: nil
        )
        #expect(wrapped.content.contains("<<<EXTERNAL_UNTRUSTED_CONTENT id=\""))
        guard case .object(let object) = wrapped.metadata,
              case .string(let kind) = object["kind"] else {
            Issue.record("expected metadata object")
            return
        }
        #expect(kind == "raw")
    }

    @Test("web_fetch output includes security preamble")
    func webFetchPreamble() {
        let call = ToolCall(name: "web_fetch", arguments: .object([:]), id: "call-1")
        let wrapped = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: result(content: "page body"),
            entry: nil
        )
        #expect(wrapped.content.contains("SECURITY NOTICE"))
    }

    @Test("skips already-wrapped content")
    func skipsAlreadyWrapped() {
        let preWrapped = ExternalContentEnvelope.wrap(
            "cached",
            options: ExternalContentEnvelopeOptions(source: .api, includeSecurityPreamble: false)
        )
        let call = ToolCall(name: "read_file", arguments: .object([:]), id: "call-1")
        let output = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: result(content: preWrapped),
            entry: nil
        )
        #expect(output.content == preWrapped)
    }

    @Test("wraps failed tool results")
    func wrapsFailures() {
        let call = ToolCall(name: "bash", arguments: .object([:]), id: "call-1")
        let output = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: result(content: "permission denied", success: false),
            entry: nil
        )
        #expect(output.success == false)
        #expect(output.content.contains("<<<EXTERNAL_UNTRUSTED_CONTENT id=\""))
    }

    @Test("preserves metadata while wrapping content")
    func preservesMetadata() {
        let metadata: JSON = .object(["kind": .string("grep-result")])
        let call = ToolCall(name: "grep", arguments: .object([:]), id: "call-1")
        let output = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: result(content: "match line", metadata: metadata),
            entry: nil
        )
        guard case .object(let object) = output.metadata,
              case .string(let kind) = object["kind"] else {
            Issue.record("expected metadata object")
            return
        }
        #expect(kind == "grep-result")
    }

    @Test("skips harness-internal finish output")
    func skipsFinish() {
        let call = ToolCall(name: TerminationToolProvider.finishToolName, arguments: .object([:]), id: "call-1")
        let raw = "Task complete."
        let output = ToolResultExternalContentMiddleware.apply(
            toolCall: call,
            result: result(content: raw),
            entry: nil
        )
        #expect(output.content == raw)
    }
}
