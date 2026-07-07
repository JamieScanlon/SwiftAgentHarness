import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PreviewStreamer")
struct PreviewStreamerTests {
    @Test("Partial mode replaces with latest full text")
    func partialMode() {
        var streamer = PreviewStreamer(mode: .partial)
        let first = streamer.ingestText("Hello")
        #expect(first == [.text("Hello")])
        let second = streamer.ingestText(" world")
        #expect(second == [.text("Hello world")])
    }

    @Test("Progress mode degrades to tool progress lines")
    func progressToolLines() {
        var streamer = PreviewStreamer(mode: .progress)
        let updates = streamer.ingestToolProgress("Searching the web…")
        #expect(updates == [.progress("Searching the web…")])
    }

    @Test("Progress mode emits ephemeral status instead of assistant text")
    func progressModeStatus() {
        var streamer = PreviewStreamer(mode: .progress)
        let first = streamer.ingestText("Hello")
        #expect(first == [.progress("Responding…")])
        let second = streamer.ingestText(" world")
        #expect(second.isEmpty)
        #expect(streamer.flush().isEmpty)
    }

    @Test("Progress mode retains accumulated text for cancellation")
    func progressModeCancellation() {
        var streamer = PreviewStreamer(mode: .progress)
        _ = streamer.ingestText("partial")
        #expect(streamer.resolveForCancellation() == .cancelled(partialText: "partial"))
    }

    @Test("Block mode emits chunked preview steps")
    func blockMode() {
        var streamer = PreviewStreamer(
            mode: .block,
            chunkerConfig: ChunkerConfig(minChars: 5, maxChars: 20, textChunkLimit: 20)
        )
        let text = String(repeating: "a", count: 30)
        let updates = streamer.ingestText(text)
        #expect(!updates.isEmpty)
    }

    @Test("Off mode emits nothing")
    func offMode() {
        var streamer = PreviewStreamer(mode: .off)
        #expect(streamer.ingestText("nope").isEmpty)
    }

    @Test("Cancellation resolves preview ephemerally")
    func cancellationResolution() {
        var streamer = PreviewStreamer(mode: .partial)
        _ = streamer.ingestText("partial")
        let resolution = streamer.resolveForCancellation()
        #expect(resolution == .cancelled(partialText: "partial"))
    }

    @Test("Final resolution replaces preview")
    func finalResolution() {
        var streamer = PreviewStreamer(mode: .partial)
        #expect(streamer.resolveForFinal() == .replacedByFinal)
    }
}

@Suite("StreamingSurfaceCapabilities")
struct StreamingSurfaceCapabilitiesTests {
    @Test("Social preset enables coalescing and natural pacing")
    func socialPreset() {
        let caps = StreamingSurfaceCapabilities.socialChannel
        #expect(caps.coalescing.enabled)
        #expect(caps.pacing.mode == .natural)
        #expect(caps.chunker.minChars >= 400)
    }

    @Test("Operator preset disables pacing")
    func operatorPreset() {
        let caps = StreamingSurfaceCapabilities.operatorChannel
        #expect(caps.pacing.mode == .off)
    }

    @Test("maxChars never exceeds textChunkLimit")
    func effectiveMaxChars() {
        let caps = StreamingSurfaceCapabilities.socialChannel
        #expect(caps.chunker.effectiveMaxChars <= caps.chunker.textChunkLimit)
    }

    @Test("Progress degrades to partial when unsupported")
    func previewDegradation() {
        var caps = StreamingSurfaceCapabilities(
            granularity: .previewEdit,
            supportedGranularities: [.previewEdit],
            previewMode: .progress,
            supportedPreviewModes: [.off, .partial]
        )
        #expect(caps.effectivePreviewMode == .partial)
    }

    @Test("Block and preview are mutually exclusive")
    func blockPreviewExclusion() {
        let caps = StreamingSurfaceCapabilities.socialChannel
        #expect(caps.usesBlockStreaming)
        #expect(!caps.usesPreviewStreaming)
    }

    @Test("Social channel surfaces tool progress in block mode")
    func blockToolProgressCapability() {
        let caps = StreamingSurfaceCapabilities.socialChannel
        #expect(caps.surfacesToolProgressInBlockMode)
    }

    @Test("Operator channel does not surface tool progress in block mode")
    func operatorNoBlockToolProgress() {
        let caps = StreamingSurfaceCapabilities.operatorChannel
        #expect(!caps.surfacesToolProgressInBlockMode)
    }
}
