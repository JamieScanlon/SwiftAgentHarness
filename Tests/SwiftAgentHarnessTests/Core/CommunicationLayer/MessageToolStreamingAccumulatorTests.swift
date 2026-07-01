import Testing
@testable import SwiftAgentHarness

@Suite("Message tool streaming accumulator")
struct MessageToolStreamingAccumulatorTests {
    @Test("streams incremental visible text from nil-name argument deltas")
    func incrementalFragments() {
        var accumulator = MessageToolStreamingAccumulator()
        accumulator.registerToolCall(id: "call-1", name: MessageToolArgumentsParser.toolName)

        let first = accumulator.ingestArgumentsFragment(
            id: "call-1",
            name: nil,
            fragment: #"{"blocks":[{"type":"text","text":"Hel"#
        )
        #expect(first == nil)

        let second = accumulator.ingestArgumentsFragment(
            id: "call-1",
            name: nil,
            fragment: #"lo"}]}"#
        )
        #expect(second == "Hello")
    }

    @Test("ignores non-message tools")
    func nonMessageTool() {
        var accumulator = MessageToolStreamingAccumulator()
        accumulator.registerToolCall(id: "call-1", name: "web_search")

        let delta = accumulator.ingestArgumentsFragment(
            id: "call-1",
            name: nil,
            fragment: #"{"query":"hello"}"#
        )
        #expect(delta == nil)
    }

    @Test("completed-only path emits visible text once")
    func completedFallback() {
        var accumulator = MessageToolStreamingAccumulator()
        accumulator.registerToolCall(id: "call-1", name: MessageToolArgumentsParser.toolName)

        let delta = accumulator.ingestCompleted(
            id: "call-1",
            name: MessageToolArgumentsParser.toolName,
            arguments: #"{"blocks":[{"type":"text","text":"Hello world"}]}"#
        )
        #expect(delta == "Hello world")

        let duplicate = accumulator.ingestCompleted(
            id: "call-1",
            name: MessageToolArgumentsParser.toolName,
            arguments: #"{"blocks":[{"type":"text","text":"Hello world"}]}"#
        )
        #expect(duplicate == nil)
    }

    @Test("completed emits only remaining suffix after partial streaming")
    func completedEmitsRemainingSuffix() {
        var accumulator = MessageToolStreamingAccumulator()
        accumulator.registerToolCall(id: "call-1", name: MessageToolArgumentsParser.toolName)
        _ = accumulator.ingestArgumentsFragment(
            id: "call-1",
            name: nil,
            fragment: #"{"blocks":[{"type":"text","text":"Hel"}"#
        )

        let delta = accumulator.ingestCompleted(
            id: "call-1",
            name: MessageToolArgumentsParser.toolName,
            arguments: #"{"blocks":[{"type":"text","text":"Hello"}]}"#
        )
        #expect(delta == "lo")
    }

    @Test("multiple text blocks join with newline")
    func multipleTextBlocks() {
        var accumulator = MessageToolStreamingAccumulator()
        accumulator.registerToolCall(id: "call-1", name: MessageToolArgumentsParser.toolName)

        let delta = accumulator.ingestCompleted(
            id: "call-1",
            name: MessageToolArgumentsParser.toolName,
            arguments: """
            {"blocks":[{"type":"text","text":"Line one"},{"type":"text","text":"Line two"}]}
            """
        )
        #expect(delta == "Line one\nLine two")
    }
}
