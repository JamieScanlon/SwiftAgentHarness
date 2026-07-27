import Foundation

/// Applies streaming surface sink semantics to a transcript owned by the TUI app actor.
public enum TUIStreamingSurfaceSinkLogic {
    public static func sendTokenDelta(_ text: String, to transcript: TranscriptListComponent) {
        let sanitized = TUITextSanitizer.sanitizeMultiline(text)
        if let view = transcript.activeStreamingView() {
            view.appendToken(sanitized)
            transcript.syncMessage(from: view)
        } else {
            let message = TUIMessage(role: .assistant, content: "", isStreaming: true)
            transcript.appendMessage(message)
            if let view = transcript.activeStreamingView() {
                view.appendToken(sanitized)
                transcript.syncMessage(from: view)
            }
        }
        transcript.invalidate()
    }

    public static func sendFinal(_ payload: StreamingFinalPayload, to transcript: TranscriptListComponent) {
        let sanitized = TUITextSanitizer.sanitizeMultiline(payload.text)
        if let view = transcript.activeStreamingView() {
            view.streamingTail = ""
            view.message.content = sanitized
            view.message.isStreaming = false
            transcript.syncMessage(from: view)
        } else if !sanitized.isEmpty {
            transcript.appendMessage(TUIMessage(role: .assistant, content: sanitized))
        }
        transcript.invalidate()
    }

    public static func emitCancellation(_ notice: CancellationNotice, to transcript: TranscriptListComponent) {
        if let view = transcript.activeStreamingView() {
            view.appendToken(notice.marker)
            view.commitStreaming()
            transcript.syncMessage(from: view)
        }
        transcript.invalidate()
    }

    /// Commits a resolved preview into the transcript.
    ///
    /// Must write the view's mutated message back: `commitStreaming()` clears
    /// `isStreaming` on the view's *value copy* only, so without the write-back
    /// `activeStreamingView()` keeps returning the finished message and the next turn's
    /// tokens land on the previous reply.
    public static func commitPreview(to transcript: TranscriptListComponent) {
        guard let view = transcript.activeStreamingView() else { return }
        view.commitStreaming()
        transcript.syncMessage(from: view)
        transcript.invalidate()
    }
}

/// Bridges ``StreamingSurfaceEngine`` callbacks back onto the TUI app actor.
public actor TUIStreamingSurfaceSink: StreamingSurfaceSink {
    private let transcriptHandler: @Sendable (TranscriptMutation) async -> Void

    public enum TranscriptMutation: Sendable {
        case tokenDelta(String)
        case reasoningDelta(String)
        case final(StreamingFinalPayload)
        case cancellation(CancellationNotice)
        case previewCommit
    }

    public init(transcriptHandler: @escaping @Sendable (TranscriptMutation) async -> Void) {
        self.transcriptHandler = transcriptHandler
    }

    public func sendTokenDelta(_ text: String) async {
        await transcriptHandler(.tokenDelta(text))
    }

    /// Routed through the engine like every other stream, so reasoning inherits the same
    /// pacing, coalescing and cancellation semantics as assistant text.
    public func sendReasoningDelta(_ text: String) async {
        await transcriptHandler(.reasoningDelta(text))
    }

    public func sendBlock(_ text: String) async {
        await sendTokenDelta(text)
    }

    public func upsertPreview(_ update: PreviewUpdate) async {
        switch update {
        case .text(let text), .progress(let text), .toolProgress(let text):
            await sendTokenDelta(text)
        }
    }

    public func resolvePreview(_ resolution: PreviewResolution) async {
        await transcriptHandler(.previewCommit)
    }

    public func sendFinal(_ payload: StreamingFinalPayload) async {
        await transcriptHandler(.final(payload))
    }

    public func emitCancellation(_ notice: CancellationNotice) async {
        await transcriptHandler(.cancellation(notice))
    }
}
