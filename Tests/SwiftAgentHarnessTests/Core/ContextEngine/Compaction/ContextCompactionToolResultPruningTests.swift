import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("ContextCompactionToolResultPruning")
struct ContextCompactionToolResultPruningTests {
    // MARK: - Empty list (only unlisted recency cap applies)

    @Test("Empty name list: single tool is unchanged (within unlisted recency cap)")
    func emptyNameListSingleToolUnchanged() {
        let tid = "call-1"
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "calling",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "HUGE PAYLOAD",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: tid
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: []
        )
        #expect(out[1].content == "HUGE PAYLOAD")
    }

    @Test("Unlisted recency cap keeps only last N tool results when name list is empty")
    func unlistedRecencyCapWithoutNamePruning() {
        var messages: [Message] = []
        for i in 0..<6 {
            let tid = "gp-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a\(i)",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "PAYLOAD-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: [],
            maxRecentUnlistedToolResults: 2
        )
        let toolContents = out.enumerated().filter { $0.element.role == .tool }.map(\.element.content)
        #expect(toolContents == [
            ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder,
            ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder,
            ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder,
            ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder,
            "PAYLOAD-4",
            "PAYLOAD-5",
        ])
    }

    // MARK: - Per-listed-name recency cap

    @Test("Per-name cap of 0 clears every listed tool result")
    func perListedNameCapZeroClearsAll() {
        let mid = UUID()
        let tid = "call-1"
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "calling",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
        )
        let t = Message(
            id: mid,
            role: .tool,
            content: "HUGE PAYLOAD",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: tid
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0
        )
        #expect(out[1].id == mid)
        #expect(out[1].toolCallId == tid)
        #expect(out[1].content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder)
    }

    @Test("Per-name cap keeps single listed tool result when cap is at least 1")
    func perListedNameCapKeepsSingleResult() {
        let mid = UUID()
        let tid = "call-1"
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "calling",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
        )
        let t = Message(
            id: mid,
            role: .tool,
            content: "HUGE PAYLOAD",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: tid
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 5
        )
        #expect(out[1].id == mid)
        #expect(out[1].toolCallId == tid)
        #expect(out[1].content == "HUGE PAYLOAD")
    }

    @Test("Per-name caps apply independently across listed tool names")
    func perListedNameCapAppliesIndependently() {
        var messages: [Message] = []
        for i in 0..<6 {
            let tid = "wf-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "F-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        for i in 0..<6 {
            let tid = "ws-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "S-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: ["web-fetch", "web-search"],
            maxRecentPerListedName: 5
        )
        let ph = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        let toolContents = out.enumerated().filter { $0.element.role == .tool }.map(\.element.content)
        // 6 web-fetch (oldest cleared, last 5 kept) followed by 6 web-search (oldest cleared, last 5 kept)
        #expect(toolContents == [
            ph, "F-1", "F-2", "F-3", "F-4", "F-5",
            ph, "S-1", "S-2", "S-3", "S-4", "S-5",
        ])
    }

    @Test("Per-name cap and unlisted recency cap operate independently on disjoint buckets")
    func perListedAndUnlistedAreIndependent() {
        var messages: [Message] = []
        for i in 0..<3 {
            let tid = "ws-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "S-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        for i in 0..<4 {
            let tid = "gp-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "P-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 5,
            maxRecentUnlistedToolResults: 2
        )
        let ph = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        let toolContents = out.enumerated().filter { $0.element.role == .tool }.map(\.element.content)
        // web-search bucket (3 results, cap=5): all kept.
        // get_plan unlisted (4 results, cap=2): oldest 2 cleared, last 2 kept.
        #expect(toolContents == [
            "S-0", "S-1", "S-2",
            ph, ph, "P-2", "P-3",
        ])
    }

    @Test("Does not prune when tool not in list")
    func unlistedToolUnchanged() {
        let tid = "x"
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "x",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: tid)]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "keep me",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: tid
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"]
        )
        #expect(out[1].content == "keep me")
    }

    @Test("Per-name cap of 0 resolves toolCallId from head when middle is only tool result")
    func namePruneUsesHeadForToolCallIdLookup() {
        let headAssistant = Message(
            id: UUID(),
            role: .assistant,
            content: "calling search",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: "ws-only")]
        )
        let onlyMiddle = [
            Message(
                id: UUID(),
                role: .tool,
                content: "RAW_SEARCH_RESULTS",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: "ws-only"
            ),
        ]
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: onlyMiddle,
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0,
            maxRecentUnlistedToolResults: 5,
            toolCallNameResolutionContext: [headAssistant]
        )
        #expect(out[0].content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder)
    }

    @Test("Listed tool with unresolvable toolCallId is never cleared (cannot attribute to name)")
    func listedToolWithUnresolvableIdUnchanged() {
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "mystery payload",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "no-assistant-for-this"
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0,
            maxRecentUnlistedToolResults: 0
        )
        #expect(out[0].content == "mystery payload")
    }

    @Test("Unresolvable tool results are never cleared by either pass")
    func unresolvableToolsSkipBothPasses() {
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "mystery payload",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "no-assistant-for-this"
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [t],
            toolNamesToPrune: [],
            maxRecentUnlistedToolResults: 0
        )
        #expect(out[0].content == "mystery payload")
    }

    @Test("Per-name cap on listed tools coexists with unlisted recency cap (per-name=1)")
    func perNameCapAndUnlistedCapTogether() {
        var messages: [Message] = []
        for i in 0..<2 {
            let tid = "ws-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "W\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        for i in 0..<3 {
            let tid = "gp-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "G\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 1,
            maxRecentUnlistedToolResults: 1
        )
        let ph = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        // web-search bucket (per-name cap=1): clears W0, keeps W1.
        // get_plan unlisted (cap=1): clears G0, G1; keeps G2.
        #expect(out[1].content == ph)
        #expect(out[3].content == "W1")
        #expect(out[5].content == ph)
        #expect(out[7].content == ph)
        #expect(out[9].content == "G2")
    }

    @Test("Listed tool name pruning leaves unlisted tools out of its bucket")
    func namePrunedExcludesFromUnlistedBucket() {
        // Two web-search (listed, per-name cap=0 clears both) and two get_plan (unlisted, recency cap=1 keeps last).
        var messages: [Message] = []
        for _ in 0..<2 {
            let tid = UUID().uuidString
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "W",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        for i in 0..<2 {
            let tid = "g-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "P-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0,
            maxRecentUnlistedToolResults: 1
        )
        let ph = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        #expect(out[1].content == ph)
        #expect(out[3].content == ph)
        #expect(out[5].content == ph)
        #expect(out[7].content == "P-1")
    }

    // MARK: - Tool identity and resolution

    @Test("Tool result without toolCallId is not name- or recency-cleared (cannot attribute)")
    func toolResultMissingToolCallIdUnchanged() {
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "call",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: "x")]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "unattributed but huge",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: nil
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0,
            maxRecentUnlistedToolResults: 0
        )
        #expect(out[1].content == "unattributed but huge")
    }

    @Test("Empty toolCallId on tool message does not match assistant toolCalls")
    func toolResultEmptyStringToolCallIdUnchanged() {
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "call",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "web-search", arguments: .object([:]), id: "real-id")]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "data",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: ""
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0
        )
        #expect(out[1].content == "data")
    }

    @Test("Assistant tool call with nil id does not map tool results by toolCallId")
    func assistantToolCallNilIdPreventsNameResolution() {
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "call",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "get_conversation", arguments: .object([:]), id: nil)]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "CONVERSATION_BODY",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: "orphan-1"
        )
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["get_conversation"],
            maxRecentPerListedName: 0
        )
        #expect(out[1].content == "CONVERSATION_BODY")
    }

    @Test("Tool name match is case- and string-sensitive: must equal prune set entry")
    func toolNameIsCaseSensitive() {
        let tid = "t-1"
        let a = Message(
            id: UUID(),
            role: .assistant,
            content: "c",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "Web-Search", arguments: .object([:]), id: tid)]
        )
        let t = Message(
            id: UUID(),
            role: .tool,
            content: "PAYLOAD",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: tid
        )
        let outLower = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["web-search"],
            maxRecentPerListedName: 0
        )
        #expect(outLower[1].content == "PAYLOAD")
        let outExact = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: [a, t],
            toolNamesToPrune: ["Web-Search"],
            maxRecentPerListedName: 0
        )
        #expect(outExact[1].content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder)
    }

    // MARK: - Recency and composition

    @Test("Unlisted recency cap keeps last N of many resolvable tool rows when names list empty")
    func recencyKeepsLast3Of7() {
        var messages: [Message] = []
        for i in 0..<7 {
            let tid = "b-\(i)"
            messages.append(
                Message(
                    id: UUID(),
                    role: .assistant,
                    content: "a",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "bash", arguments: .object([:]), id: tid)]
                )
            )
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: "out-\(i)",
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: tid
                )
            )
        }
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: messages,
            toolNamesToPrune: [],
            maxRecentUnlistedToolResults: 3
        )
        let toolContents = out.enumerated().filter { $0.element.role == .tool }.map(\.element.content)
        let ph = ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder
        #expect(
            toolContents == [
                ph, ph, ph, ph,
                "out-4", "out-5", "out-6",
            ]
        )
    }

    @Test("Head context resolves listed tool in middle that appears before any assistant in middle slice")
    func headResolvesFirstMiddleTool() {
        let headA = Message(
            id: UUID(),
            role: .assistant,
            content: "from head",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "get_conversation", arguments: .object([:]), id: "gc-0")]
        )
        let middle = [
            Message(
                id: UUID(),
                role: .tool,
                content: "HUGE",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: "gc-0"
            ),
        ]
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: middle,
            toolNamesToPrune: ["get_conversation"],
            maxRecentPerListedName: 0,
            maxRecentUnlistedToolResults: 5,
            toolCallNameResolutionContext: [headA]
        )
        #expect(out[0].content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder)
    }

    @Test("Non-user roles among middle do not break mapping: only assistant toolCalls count")
    func userMessageInMiddleDoesNotProvideToolNameMap() {
        let tid = "t1"
        let middle: [Message] = [
            Message(id: UUID(), role: .user, content: "u", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "a",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: tid)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "FETCH",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: tid
            ),
        ]
        let out = ContextCompactionToolResultPruning.applyingToolResultContentPruningForCompactionLLM(
            messages: middle,
            toolNamesToPrune: ["web-fetch"],
            maxRecentPerListedName: 0
        )
        #expect(out[2].content == ContextCompactionToolResultPruning.clearedToolResultContentPlaceholder)
    }
}
