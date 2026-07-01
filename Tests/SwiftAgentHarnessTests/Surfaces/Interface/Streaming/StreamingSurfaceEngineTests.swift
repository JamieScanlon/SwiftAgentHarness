import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("StreamingSurfaceEngine")
struct StreamingSurfaceEngineTests {
    @Test("Token delta forwards text fragments")
    func tokenDelta() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        await engine.ingest(.text("Hel"))
        await engine.ingest(.text("lo"))
        await engine.finish(final: StreamingFinalPayload(text: "Hello"))
        let actions = await sink.actions
        #expect(actions.contains(.tokenDelta("Hel")))
        #expect(actions.contains(.tokenDelta("lo")))
        #expect(actions.contains(.final(StreamingFinalPayload(text: "Hello"))))
    }

    @Test("Block streaming emits chunks on text_end")
    func blockTextEnd() async {
        var caps = StreamingSurfaceCapabilities.operatorChannel
        caps.chunker = ChunkerConfig(minChars: 5, maxChars: 30, textChunkLimit: 30)
        caps.coalescing = CoalescingConfig(enabled: false)

        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        let text = String(repeating: "a", count: 40)
        await engine.ingest(.text(text))
        await engine.finish(final: StreamingFinalPayload(text: text))

        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(!blocks.isEmpty)
        #expect(blocks.joined().count >= 40)
    }

    @Test("Block streaming buffers until message_end")
    func blockMessageEnd() async {
        var caps = StreamingSurfaceCapabilities.operatorChannel
        caps.blockStreaming = BlockStreamingConfig(enabled: true, breakBoundary: .messageEnd)
        caps.chunker = ChunkerConfig(minChars: 5, maxChars: 30, textChunkLimit: 30)

        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("first "))
        await engine.ingest(.text("second"))
        let midBlocks = await sink.actions.filter {
            if case .block = $0 { return true }
            return false
        }
        #expect(midBlocks.isEmpty)

        await engine.finish(final: StreamingFinalPayload(text: "first second"))
        let lateBlocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(!lateBlocks.isEmpty)
    }

    @Test("Preview streaming when block streaming disabled")
    func previewStreaming() async {
        var caps = StreamingSurfaceCapabilities(
            granularity: .previewEdit,
            supportedGranularities: [.previewEdit, .finalOnly],
            blockStreaming: BlockStreamingConfig(enabled: false),
            previewMode: .partial,
            supportedPreviewModes: [.partial, .progress]
        )
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("Thinking"))
        await engine.ingest(.toolCall(toolName: "web_search", toolCallId: "1", argumentsFragment: nil, blockIndex: nil))
        await engine.finish(final: StreamingFinalPayload(text: "Done"))

        let actions = await sink.actions
        #expect(actions.contains(.preview(.text("Thinking"))))
        #expect(actions.contains(where: {
            if case .preview(.toolProgress(let line)) = $0 { return line.contains("Searching") }
            return false
        }))
        #expect(actions.contains(.previewResolved(.replacedByFinal)))
    }

    @Test("Block and preview are mutually exclusive per turn")
    func mutualExclusion() async {
        let caps = StreamingSurfaceCapabilities.socialChannel
        #expect(caps.usesBlockStreaming)
        #expect(!caps.usesPreviewStreaming)

        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("streamed"))
        await engine.finish(final: StreamingFinalPayload(text: "streamed"))

        let previews = await sink.actions.filter {
            if case .preview = $0 { return true }
            return false
        }
        #expect(previews.isEmpty)
    }

    @Test("Final only sends on finish")
    func finalOnly() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .finalOnly, sink: sink)
        await engine.ingest(.text("hidden"))
        await engine.finish(final: StreamingFinalPayload(text: "hidden"))

        let actions = await sink.actions
        #expect(!actions.contains(where: {
            if case .tokenDelta = $0 { return true }
            if case .block = $0 { return true }
            return false
        }))
        #expect(actions.contains(.final(StreamingFinalPayload(text: "hidden"))))
    }

    @Test("Cancellation on block granularity appends marker")
    func blockCancellation() async {
        var caps = StreamingSurfaceCapabilities.operatorChannel
        caps.chunker = ChunkerConfig(minChars: 3, maxChars: 100, textChunkLimit: 100)
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("partial work"))
        await engine.cancel()

        let actions = await sink.actions
        #expect(actions.contains(.block("_(cancelled)_")))
    }

    @Test("Cancellation on preview resolves scratch preview")
    func previewCancellation() async {
        var caps = StreamingSurfaceCapabilities(
            granularity: .previewEdit,
            supportedGranularities: [.previewEdit],
            previewMode: .partial,
            supportedPreviewModes: [.partial]
        )
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("live"))
        await engine.cancel()

        let actions = await sink.actions
        #expect(actions.contains(.previewResolved(.cancelled(partialText: "live"))))
    }

    @Test("Consume helper drives full stream")
    func consumeStream() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        let stream = AsyncStream<ChatStreamingPartial> { continuation in
            continuation.yield(.text("A"))
            continuation.yield(.text("B"))
            continuation.finish()
        }
        await engine.consume(stream: stream, final: StreamingFinalPayload(text: "AB"))
        let actions = await sink.actions
        #expect(actions.count >= 3)
    }

    @Test("flushSegment emits pending block without finalizing")
    func flushSegment() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .socialChannel, sink: sink)
        await engine.ingest(.text("segment one"))
        await engine.flushSegment()
        await engine.ingest(.text(" segment two"))
        await engine.finish(final: StreamingFinalPayload(text: "committed reply"))
        let actions = await sink.actions
        let blockCount = actions.filter {
            if case .block = $0 { return true }
            return false
        }.count
        #expect(blockCount >= 2)
        #expect(actions.contains(.final(StreamingFinalPayload(text: "committed reply"))))
    }

    @Test("flushSegment is no-op at token-delta granularity")
    func flushSegmentTokenDeltaNoOp() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        await engine.ingest(.text("live"))
        await engine.flushSegment()
        await engine.finish(final: StreamingFinalPayload(text: "live"))
        let actions = await sink.actions
        #expect(!actions.contains(where: { if case .block = $0 { return true }; return false }))
    }

    @Test("Coalescing merges blocks through the live ingest path")
    func coalescingLiveMerge() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: coalescingTestCaps(), sink: sink)
        await engine.ingest(.text("aaa\n\n"))
        await engine.ingest(.text("bbb\n\n"))
        await engine.ingest(.text("ccc\n\n"))
        await engine.awaitCoalesceFlush()
        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("aaa"))
        #expect(blocks[0].contains("bbb"))
        #expect(blocks[0].contains("ccc"))
    }

    @Test("Finish cancels the debounce timer with no double-send")
    func finishCancelsCoalesceTimer() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: coalescingTestCaps(), sink: sink)
        await engine.ingest(.text("aaa\n\n"))
        await engine.ingest(.text("bbb\n\n"))
        await engine.finish(final: StreamingFinalPayload(text: "aaa bbb ccc"))
        await engine.awaitCoalesceFlush()
        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("aaa"))
        #expect(blocks[0].contains("bbb"))
        let actions = await sink.actions
        #expect(actions.contains(.final(StreamingFinalPayload(text: "aaa bbb ccc"))))
    }

    @Test("Block channel surfaces tool progress during tool-heavy turns")
    func blockToolProgress() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .socialChannel, sink: sink)
        await engine.ingest(.toolCall(toolName: "web_search", toolCallId: "1", argumentsFragment: nil, blockIndex: nil))
        await engine.finish(final: StreamingFinalPayload(text: "Done"))

        let actions = await sink.actions
        #expect(actions.contains(where: {
            if case .preview(.toolProgress(let line)) = $0 { return line.contains("Searching") }
            return false
        }))
    }

    @Test("Operator block channel does not surface tool progress")
    func operatorNoToolProgress() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .operatorChannel, sink: sink)
        await engine.ingest(.toolCall(toolName: "web_search", toolCallId: "1", argumentsFragment: nil, blockIndex: nil))
        await engine.finish(final: StreamingFinalPayload(text: "Done"))

        let previews = await sink.actions.filter {
            if case .preview = $0 { return true }
            return false
        }
        #expect(previews.isEmpty)
    }

    @Test("Message end boundary flushes through coalescer")
    func messageEndCoalescing() async {
        var caps = StreamingSurfaceCapabilities.socialChannel
        caps.blockStreaming = BlockStreamingConfig(enabled: true, breakBoundary: .messageEnd)
        caps.coalescing = CoalescingConfig(enabled: true, idleMs: 30, minChars: 14)
        caps.pacing = PacingConfig(mode: .off)
        caps.chunker = ChunkerConfig(minChars: 3, maxChars: 2000, textChunkLimit: 4000)

        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        await engine.ingest(.text("aaa\n\n"))
        await engine.ingest(.text("bbb\n\n"))
        await engine.finish(final: StreamingFinalPayload(text: "aaa bbb"))

        let blocks = await sink.actions.compactMap { action -> String? in
            if case .block(let text) = action { return text }
            return nil
        }
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("aaa"))
        #expect(blocks[0].contains("bbb"))
    }

    @Test("Reasoning deltas route to token-delta terminals")
    func reasoningDeltaTokenDelta() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        await engine.ingest(.reasoning("thinking", blockIndex: nil))
        await engine.finish(final: StreamingFinalPayload(text: "Done"))

        let actions = await sink.actions
        #expect(actions.contains(.reasoningDelta("thinking")))
    }

    @Test("Reasoning deltas are dropped at block granularity")
    func reasoningDeltaBlockDropped() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .operatorChannel, sink: sink)
        await engine.ingest(.reasoning("thinking", blockIndex: nil))
        await engine.finish(final: StreamingFinalPayload(text: "Done"))

        let actions = await sink.actions
        #expect(!actions.contains(where: {
            if case .reasoningDelta = $0 { return true }
            return false
        }))
    }

    @Test("Final is ordered after paced blocks")
    func finalAfterPacedBlocks() async {
        var caps = StreamingSurfaceCapabilities.operatorChannel
        caps.pacing = PacingConfig(mode: .custom(minMs: 50, maxMs: 50))
        caps.chunker = ChunkerConfig(minChars: 5, maxChars: 15, textChunkLimit: 15)
        caps.coalescing = CoalescingConfig(enabled: false)

        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: caps, sink: sink)
        let text = String(repeating: "a", count: 40)
        await engine.ingest(.text(text))
        await engine.finish(final: StreamingFinalPayload(text: "committed final"))

        let actions = await sink.actions
        let blockIndices = actions.indices.filter {
            if case .block = actions[$0] { return true }
            return false
        }
        let finalIndex = actions.firstIndex {
            if case .final = $0 { return true }
            return false
        }
        #expect(!blockIndices.isEmpty)
        #expect(finalIndex != nil)
        if let finalIndex {
            #expect(blockIndices.allSatisfy { $0 < finalIndex })
        }
    }

    @Test("Message tool arg fragments render visible text at token delta")
    func messageToolPartialRenderingTokenDelta() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        await engine.ingest(.toolCallStarted(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            contentIndex: 0
        ))
        await engine.ingest(.toolCall(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            argumentsFragment: #"{"blocks":[{"type":"text","text":"Hel"#,
            blockIndex: nil
        ))
        await engine.ingest(.toolCall(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            argumentsFragment: #"lo"}]}"#,
            blockIndex: nil
        ))
        await engine.finish(final: StreamingFinalPayload(text: "Hello"))
        let actions = await sink.actions
        #expect(actions.contains(.tokenDelta("Hello")))
    }

    @Test("Message tool completed args render when args were buffered")
    func messageToolCompletedRendering() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        let arguments = #"{"blocks":[{"type":"text","text":"buffered visible"}]}"#
        await engine.ingest(.toolCallStarted(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            contentIndex: 0
        ))
        await engine.ingest(.toolCallCompleted(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            arguments: arguments,
            blockIndex: nil
        ))
        await engine.finish(final: StreamingFinalPayload(text: "buffered visible"))
        let actions = await sink.actions
        #expect(actions.contains(.tokenDelta("buffered visible")))
    }

    @Test("Message tool visible text suppressed when prose already streamed")
    func messageToolDuplicateSuppressed() async {
        let sink = RecordingStreamingSurfaceSink()
        let engine = StreamingSurfaceEngine(capabilities: .terminal, sink: sink)
        await engine.ingest(.text("Hello world"))
        await engine.ingest(.toolCall(
            toolName: MessageToolArgumentsParser.toolName,
            toolCallId: "call-1",
            argumentsFragment: #"{"blocks":[{"type":"text","text":"Hello world"}]}"#,
            blockIndex: nil
        ))
        await engine.finish(final: StreamingFinalPayload(text: "Hello world"))
        let tokenDeltas = await sink.actions.compactMap { action -> String? in
            if case .tokenDelta(let text) = action { return text }
            return nil
        }
        #expect(tokenDeltas.joined() == "Hello world")
    }
}

private func coalescingTestCaps() -> StreamingSurfaceCapabilities {
    var caps = StreamingSurfaceCapabilities.operatorChannel
    caps.coalescing = CoalescingConfig(enabled: true, idleMs: 30, minChars: 14)
    caps.pacing = PacingConfig(mode: .off)
    caps.chunker = ChunkerConfig(minChars: 3, maxChars: 2000, textChunkLimit: 4000)
    return caps
}
