import Foundation

/// Notice emitted when a turn is cancelled mid-stream.
public struct CancellationNotice: Sendable, Equatable {
    public var marker: String
    public var partialText: String?

    public init(marker: String, partialText: String? = nil) {
        self.marker = marker
        self.partialText = partialText
    }
}

/// Actions the surface should take when a turn is cancelled, per granularity rung.
public enum StreamingCancellationAction: Sendable, Equatable {
    case keepPartial(partialText: String)
    case appendCancellationMarker(marker: String)
    case resolvePreview(PreviewResolution)
    case emitNotice(CancellationNotice)
}

/// Applies per-granularity cancellation policy from the streaming spec.
public enum StreamingCancellation {
    public static func resolve(
        granularity: StreamingGranularity,
        partialText: String,
        cancellationMarker: String
    ) -> [StreamingCancellationAction] {
        switch granularity {
        case .tokenDelta:
            if partialText.isEmpty {
                return [.emitNotice(CancellationNotice(marker: cancellationMarker))]
            }
            return [
                .keepPartial(partialText: partialText),
                .emitNotice(CancellationNotice(marker: cancellationMarker, partialText: partialText)),
            ]
        case .block:
            return [.appendCancellationMarker(marker: cancellationMarker)]
        case .previewEdit:
            if partialText.isEmpty {
                return [.resolvePreview(.removed)]
            }
            return [.resolvePreview(.cancelled(partialText: partialText))]
        case .finalOnly:
            return [.emitNotice(CancellationNotice(marker: cancellationMarker))]
        }
    }
}
