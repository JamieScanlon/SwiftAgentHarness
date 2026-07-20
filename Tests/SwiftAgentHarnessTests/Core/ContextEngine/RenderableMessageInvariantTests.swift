import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("RenderableMessageInvariant pre-dispatch guard (CR-C)")
struct RenderableMessageInvariantTests {

    private func system(_ content: String = "sys") -> Message {
        Message(id: UUID(), role: .system, content: content, timestamp: Date(), toolCalls: [])
    }

    private func user(_ content: String) -> Message {
        Message(id: UUID(), role: .user, content: content, timestamp: Date(), toolCalls: [])
    }

    private func assistant(toolCallID: String, name: String = "do_thing") -> Message {
        Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [ToolCall(name: name, arguments: .object([:]), id: toolCallID)]
        )
    }

    private func tool(toolCallID: String, content: String = "result") -> Message {
        Message(id: UUID(), role: .tool, content: content, timestamp: Date(), toolCalls: [], toolCallId: toolCallID)
    }

    @Test("orphaned tool result (no matching assistant call) is dropped")
    func orphanToolDropped() {
        let messages = [system(), tool(toolCallID: "missing"), user("hi")]
        let result = RenderableMessageInvariant.repairToolPairs(messages)
        #expect(!result.contains { $0.role == .tool })
        #expect(result.map(\.role) == [.system, .user])
    }

    @Test("paired tool result is retained")
    func pairedToolRetained() {
        let messages = [system(), assistant(toolCallID: "call-1"), tool(toolCallID: "call-1"), user("next")]
        let result = RenderableMessageInvariant.repairToolPairs(messages)
        #expect(result.count == messages.count)
        #expect(result.contains { $0.role == .tool && $0.toolCallId == "call-1" })
    }

    @Test("array beginning with a tool result is repaired so it no longer leads with .tool")
    func leadingToolRepaired() {
        let messages = [tool(toolCallID: "call-1"), user("hello")]
        let result = RenderableMessageInvariant.repairToolPairs(messages)
        #expect(result.first?.role != .tool)
        #expect(result.map(\.role) == [.user])
    }

    @Test("missing system prompt is injected at index 0")
    func systemInjectedWhenMissing() {
        let messages = [user("hello")]
        let result = RenderableMessageInvariant.ensuringSystemPrompt(messages)
        #expect(result.first?.role == .system)
        #expect(result.count == 2)
    }

    @Test("existing system prompt is not duplicated")
    func systemNotDuplicatedWhenPresent() {
        let messages = [system(), user("hello")]
        let result = RenderableMessageInvariant.ensuringSystemPrompt(messages)
        #expect(result.filter { $0.role == .system }.count == 1)
        #expect(result.count == 2)
    }

    @Test("sanitizeForDispatch drops orphan tool and injects system in one pass")
    func sanitizeRepairsAndInjects() {
        let messages = [tool(toolCallID: "missing"), user("please continue")]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        #expect(result.first?.role == .system)
        #expect(!result.contains { $0.role == .tool })
        #expect(result.contains { $0.role == .user && $0.content == "please continue" })
    }

    @Test("tool_response-wrapped user content is not a renderable user query")
    func toolResponseWrapperIsNotRenderable() {
        let wrapped = user("<tool_response>ok</tool_response>")
        #expect(!RenderableMessageInvariant.isRenderableUserQuery(wrapped))
        #expect(RenderableMessageInvariant.isToolResponseWrapper(wrapped.content))
    }

    @Test("sanitizeForDispatch repairs system+assistant+tool+assistant with no user turn")
    func sanitizeRepairsMissingUserOnAssistantToolChain() {
        let messages = [
            system(),
            assistant(toolCallID: "call-1"),
            tool(toolCallID: "call-1"),
            Message(id: UUID(), role: .assistant, content: "done", timestamp: Date(), toolCalls: []),
        ]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        #expect(result.contains(where: RenderableMessageInvariant.isRenderableUserQuery))
        #expect(result.contains { $0.role == .tool && $0.toolCallId == "call-1" })
    }

    @Test("sanitizeForDispatch promotes merged compaction summary to standalone user")
    func sanitizePromotesMergedCompactionSummary() {
        let framed = ContextCompactionSummaryMessageAssembler.referenceOnlyPrefix + "## Active Task\nfinish the workout"
        let messages = [
            system(),
            Message(id: UUID(), role: .assistant, content: framed + "\n\nPartial reply", timestamp: Date(), toolCalls: []),
            assistant(toolCallID: "call-2"),
            tool(toolCallID: "call-2"),
        ]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        let users = result.filter(RenderableMessageInvariant.isRenderableUserQuery)
        #expect(users.count >= 1)
        #expect(users[0].content.contains("REFERENCE ONLY"))
        #expect(users[0].content.contains("## Active Task"))
    }

    @Test("sanitizeForDispatch injects Active Task text when no user and no framed summary")
    func sanitizeInjectsActiveTaskAsLastResort() {
        let messages = [
            system(),
            Message(
                id: UUID(),
                role: .assistant,
                content: "## Active Task\nbuild the fitness app\n\n## Goal\nship MVP",
                timestamp: Date(),
                toolCalls: []
            ),
        ]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        let users = result.filter(RenderableMessageInvariant.isRenderableUserQuery)
        #expect(users.count == 1)
        #expect(users[0].content.contains("build the fitness app"))
        #expect(HarnessInjectedMessageMetadata.isHarnessInjected(users[0]))
    }

    @Test("continuation-shaped array without user is repaired to a renderable user query")
    func continuationShapedArrayGetsRenderableUser() {
        // Mimics post-compaction continuation: no new appendInput user text.
        let messages = [
            system(),
            assistant(toolCallID: "c1"),
            tool(toolCallID: "c1", content: "tool out"),
            Message(id: UUID(), role: .assistant, content: "thinking…", timestamp: Date(), toolCalls: []),
        ]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        #expect(result.contains(where: RenderableMessageInvariant.isRenderableUserQuery))
        #expect(!result.contains { $0.role == .user && RenderableMessageInvariant.isToolResponseWrapper($0.content) })
    }

    @Test("user that is only a tool_response wrapper triggers repair")
    func onlyToolResponseUserTriggersRepair() {
        let messages = [
            system(),
            user("<tool_response>result</tool_response>"),
            Message(id: UUID(), role: .assistant, content: "ok", timestamp: Date(), toolCalls: []),
        ]
        let result = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: nil)
        #expect(result.contains(where: RenderableMessageInvariant.isRenderableUserQuery))
    }
}
