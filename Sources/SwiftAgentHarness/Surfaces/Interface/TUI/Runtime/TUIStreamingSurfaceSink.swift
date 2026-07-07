import Foundation

/// Applies streaming surface sink semantics to a transcript owned by the TUI app actor.
public enum TUIStreamingSurfaceSinkLogic {
    public static func sendTokenDelta(_ text: String, to transcript: TranscriptListComponent) {
        if let view = transcript.activeStreamingView() {
            view.appendToken(text)
            if let index = transcript.messages.firstIndex(where: { $0.id == view.message.id }) {
                transcript.messages[index].isStreaming = true
            }
        } else {
            let message = TUIMessage(role: .assistant, content: "", isStreaming: true)
            transcript.appendMessage(message)
            transcript.activeStreamingView()?.appendToken(text)
        }
        transcript.invalidate()
    }

    public static func sendFinal(_ payload: StreamingFinalPayload, to transcript: TranscriptListComponent) {
        if let view = transcript.activeStreamingView() {
            view.streamingTail = ""
            view.message.content = payload.text
            view.message.isStreaming = false
            if let index = transcript.messages.firstIndex(where: { $0.id == view.message.id }) {
                transcript.messages[index] = view.message
            }
        } else if !payload.text.isEmpty {
            transcript.appendMessage(TUIMessage(role: .assistant, content: payload.text))
        }
        transcript.invalidate()
    }

    public static func emitCancellation(_ notice: CancellationNotice, to transcript: TranscriptListComponent) {
        if let view = transcript.activeStreamingView() {
            view.appendToken(notice.marker)
            view.commitStreaming()
            if let index = transcript.messages.firstIndex(where: { $0.id == view.message.id }) {
                transcript.messages[index] = view.message
            }
        }
        transcript.invalidate()
    }
}

/// Bridges ``StreamingSurfaceEngine`` callbacks back onto the TUI app actor.
public actor TUIStreamingSurfaceSink: StreamingSurfaceSink {
    private let transcriptHandler: @Sendable (TranscriptMutation) async -> Void

    public enum TranscriptMutation: Sendable {
        case tokenDelta(String)
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
