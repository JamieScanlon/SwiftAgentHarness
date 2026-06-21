import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionMessageSplit")
struct ContextEngineCompactionSplitTests {
    private func tightSplitOptions() -> ContextCompactionSplitOptions {
        ContextCompactionSplitOptions(
            headMinMessageCount: 1,
            tailMinMessageCount: 1,
            tailTokenBudget: 1,
            charactersPerToken: 4
        )
    }

    private func specDefaultSplitOptions() -> ContextCompactionSplitOptions {
        ContextCompactionSplitOptions.specDefaults(proactiveThresholdTokens: 167_000)
    }

    @Test("empty transcript yields empty segments")
    func emptyTranscriptYieldsEmptySegments() {
        let segments = ContextCompactionMessageSplit.splitForCompaction([], options: tightSplitOptions())
        #expect(segments.head.isEmpty)
        #expect(segments.middle.isEmpty)
        #expect(segments.tail.isEmpty)
    }

    @Test("non-compressible transcript returns no-op split")
    func nonCompressibleTranscriptIsNoOp() {
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a3", timestamp: Date(), toolCalls: []),
        ]
        var options = tightSplitOptions()
        options.headMinMessageCount = messages.count
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: options)
        #expect(segments.head.map(\.id) == messages.map(\.id))
        #expect(segments.middle.isEmpty)
        #expect(segments.tail.isEmpty)
    }

    @Test("compressible transcript yields non-empty middle")
    func compressibleTranscriptYieldsMiddle() {
        let toolCallID = "tc-split-1"
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "payload",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: tightSplitOptions())
        #expect(!segments.middle.isEmpty)
        #expect(segments.middle.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }))
        #expect(segments.middle.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID }))
    }

    @Test("latest user is preserved in tail when middle exists")
    func latestUserPreservedInTail() {
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a4", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a5", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a6", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a7", timestamp: Date(), toolCalls: []),
        ]
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: tightSplitOptions())
        #expect(!segments.middle.isEmpty)
        #expect(segments.tail.contains(where: { $0.role == .user && $0.content == "u2" }))
    }

    @Test("boundary keeps assistant tool call and tool result in the same segment")
    func boundaryShiftsForToolPairSafety() {
        let toolCallID = "tc-boundary-1"
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "prep", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "result",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
        ]
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: tightSplitOptions())
        #expect(segments.middle.contains(where: { $0.role == .assistant && $0.content == "prep" }))
        let toolInMiddle = segments.middle.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID })
        let toolInTail = segments.tail.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID })
        #expect(toolInMiddle || toolInTail)
        if toolInMiddle {
            #expect(segments.middle.contains(where: { $0.role == .assistant && $0.toolCalls.contains { $0.id == toolCallID } }))
        }
        if toolInTail {
            #expect(segments.tail.contains(where: { $0.role == .assistant && $0.toolCalls.contains { $0.id == toolCallID } }))
        }
    }

    @Test("spec default options yield middle on long threads")
    func specDefaultsYieldMiddleOnLongThreads() {
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<20 {
            let chunk = String(repeating: "x", count: 8_000)
            messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: specDefaultSplitOptions())
        #expect(segments.tail.count >= 6)
        #expect(!segments.middle.isEmpty)
    }

    @Test("checkpoint support split preserves tail user and tool pairs with production config")
    func checkpointSupportSplitWithProductionConfig() {
        let toolCallID = "tc-prod-1"
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<18 {
            let chunk = String(repeating: "x", count: 8_000)
            messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        messages.append(contentsOf: [
            Message(id: UUID(), role: .assistant, content: "prep", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "get_plan", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "result",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u-final", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a-final", timestamp: Date(), toolCalls: []),
        ])
        let config = ContextCompactionConfiguration.default
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(!segments.middle.isEmpty)
        #expect(segments.tail.contains(where: { $0.role == .user && $0.content == "u-final" }))
        let toolInMiddle = segments.middle.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID })
        let toolInTail = segments.tail.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID })
        #expect(toolInMiddle || toolInTail)
        if toolInMiddle {
            #expect(segments.middle.contains(where: { $0.role == .assistant && $0.toolCalls.contains { $0.id == toolCallID } }))
        }
        if toolInTail {
            #expect(segments.tail.contains(where: { $0.role == .assistant && $0.toolCalls.contains { $0.id == toolCallID } }))
        }
    }

    @Test("multi-tool batch boundary does not orphan tool results in tail")
    func multiToolBatchBoundaryDoesNotOrphanToolResults() {
        let ids = (0..<3).map { _ in UUID().uuidString }
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "batch",
                timestamp: Date(),
                toolCalls: ids.map { ToolCall(name: "tool", arguments: .object([:]), id: $0) }
            ),
            Message(id: UUID(), role: .tool, content: "r1", timestamp: Date(), toolCalls: [], toolCallId: ids[0]),
            Message(id: UUID(), role: .tool, content: "r2", timestamp: Date(), toolCalls: [], toolCallId: ids[1]),
            Message(id: UUID(), role: .tool, content: "r3", timestamp: Date(), toolCalls: [], toolCallId: ids[2]),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
        ]
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: tightSplitOptions())
        #expect(segments.tail.first?.role != .tool)
        let tailToolIDs = Set(segments.tail.compactMap(\.toolCallId))
        let tailAssistantCallIDs = Set(segments.tail.flatMap(\.toolCalls).compactMap(\.id))
        for toolID in tailToolIDs {
            #expect(tailAssistantCallIDs.contains(toolID))
        }
    }

    @Test("tail boundary fail-closed when tool call IDs are missing")
    func tailBoundaryFailClosedOnMissingToolCallIDs() {
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "x", arguments: .object([:]), id: "")]
            ),
            Message(id: UUID(), role: .tool, content: "result", timestamp: Date(), toolCalls: [], toolCallId: nil),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
        ]
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: tightSplitOptions())
        #expect(segments.tail.first?.role != .tool)
    }

    @Test("head boundary keeps assistant tool call and tool result together")
    func headBoundaryKeepsToolPairIntact() {
        let toolCallID = "tc-head-1"
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "x", arguments: .object([:]), id: toolCallID)]
            ),
            Message(id: UUID(), role: .tool, content: "result", timestamp: Date(), toolCalls: [], toolCallId: toolCallID),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a3", timestamp: Date(), toolCalls: []),
        ]
        var options = tightSplitOptions()
        options.headMinMessageCount = 2
        let segments = ContextCompactionMessageSplit.splitForCompaction(messages, options: options)
        let headHasDanglingCall = segments.head.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })
            && !segments.head.contains(where: { $0.role == .tool })
        #expect(!headHasDanglingCall)
        #expect(segments.middle.first?.role != .tool)
    }

    @Test("long agent run yields non-empty middle with single early user")
    func longAgentRunYieldsNonEmptyMiddle() {
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "do the task", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<100 {
            let chunk = String(repeating: "s", count: 4_000)
            messages.append(Message(id: UUID(), role: .assistant, content: "step \(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            if idx.isMultiple(of: 5) {
                let tc = "tc-\(idx)"
                messages.append(Message(
                    id: UUID(),
                    role: .assistant,
                    content: "tool",
                    timestamp: Date(),
                    toolCalls: [ToolCall(name: "x", arguments: .object([:]), id: tc)]
                ))
                messages.append(Message(id: UUID(), role: .tool, content: "out", timestamp: Date(), toolCalls: [], toolCallId: tc))
            }
        }
        let config = ContextCompactionConfiguration.default
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(!segments.middle.isEmpty)
    }

    @Test("single early user does not disable compaction via last-user pin")
    func lastUserInHeadDoesNotDisableCompaction() {
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "only user", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<80 {
            let chunk = String(repeating: "y", count: 4_000)
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        let config = ContextCompactionConfiguration.default
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(!segments.middle.isEmpty)
        #expect(segments.head.count < messages.count)
    }

    @Test("early second user does not pin when outside natural tail window")
    func earlySecondUserDoesNotPinWhenOutsideTailWindow() {
        let u2ID = UUID()
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a3", timestamp: Date(), toolCalls: []),
            Message(id: u2ID, role: .user, content: "u2-early", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<80 {
            let chunk = String(repeating: "z", count: 4_000)
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        let config = ContextCompactionConfiguration.default
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            messages,
            config: config,
            modelContextLimitTokens: 200_000
        )
        #expect(!segments.middle.isEmpty)
        #expect(segments.middle.count > 10)
        #expect(segments.lastUserPinSkipped)
        #expect(segments.tail.first?.id != u2ID)
        #expect(segments.tail.contains(where: { $0.content.hasPrefix("a7") || $0.content.hasPrefix("a75") }) || segments.tail.count >= config.tailMinMessageCount)
    }
}
