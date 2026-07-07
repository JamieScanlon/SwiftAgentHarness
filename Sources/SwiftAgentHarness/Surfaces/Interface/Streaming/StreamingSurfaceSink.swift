import Foundation

/// Outbound seam a concrete surface implements to deliver paced streaming output.
public protocol StreamingSurfaceSink: Sendable {
    func sendTokenDelta(_ text: String) async
    func sendReasoningDelta(_ text: String) async
    func sendBlock(_ text: String) async
    func upsertPreview(_ update: PreviewUpdate) async
    func resolvePreview(_ resolution: PreviewResolution) async
    func sendFinal(_ payload: StreamingFinalPayload) async
    func emitCancellation(_ notice: CancellationNotice) async
}

public extension StreamingSurfaceSink {
    func sendTokenDelta(_ text: String) async {}
    func sendReasoningDelta(_ text: String) async {}
    func sendBlock(_ text: String) async {}
    func upsertPreview(_ update: PreviewUpdate) async {}
    func resolvePreview(_ resolution: PreviewResolution) async {}
    func sendFinal(_ payload: StreamingFinalPayload) async {}
    func emitCancellation(_ notice: CancellationNotice) async {}
}

/// Recorded outbound action for test assertions.
public enum RecordedStreamingAction: Sendable, Equatable {
    case tokenDelta(String)
    case reasoningDelta(String)
    case block(String)
    case preview(PreviewUpdate)
    case previewResolved(PreviewResolution)
    case final(StreamingFinalPayload)
    case cancellation(CancellationNotice)
}

/// In-memory sink that records all outbound actions.
public actor RecordingStreamingSurfaceSink: StreamingSurfaceSink {
    public private(set) var actions: [RecordedStreamingAction] = []

    public init() {}

    public func sendTokenDelta(_ text: String) async {
        actions.append(.tokenDelta(text))
    }

    public func sendReasoningDelta(_ text: String) async {
        actions.append(.reasoningDelta(text))
    }

    public func sendBlock(_ text: String) async {
        actions.append(.block(text))
    }

    public func upsertPreview(_ update: PreviewUpdate) async {
        actions.append(.preview(update))
    }

    public func resolvePreview(_ resolution: PreviewResolution) async {
        actions.append(.previewResolved(resolution))
    }

    public func sendFinal(_ payload: StreamingFinalPayload) async {
        actions.append(.final(payload))
    }

    public func emitCancellation(_ notice: CancellationNotice) async {
        actions.append(.cancellation(notice))
    }

    public func reset() {
        actions = []
    }
}
