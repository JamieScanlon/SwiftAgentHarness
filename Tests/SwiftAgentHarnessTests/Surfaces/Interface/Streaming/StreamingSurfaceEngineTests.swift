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
}
