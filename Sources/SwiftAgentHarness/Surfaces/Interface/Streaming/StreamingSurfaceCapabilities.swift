import Foundation

/// Preview streaming mode for in-place scratch message updates.
public enum PreviewMode: String, Sendable, Codable, CaseIterable, Hashable {
    case off
    case partial
    case block
    case progress
}

public struct BlockStreamingConfig: Sendable, Equatable, Hashable {
    public var enabled: Bool
    public var breakBoundary: BlockBreakBoundary

    public init(enabled: Bool = false, breakBoundary: BlockBreakBoundary = .textEnd) {
        self.enabled = enabled
        self.breakBoundary = breakBoundary
    }
}

public struct ChunkerConfig: Sendable, Equatable, Hashable {
    public var minChars: Int
    public var maxChars: Int
    public var textChunkLimit: Int
    public var maxLines: Int?

    public init(minChars: Int = 200, maxChars: Int = 2000, textChunkLimit: Int = 4000, maxLines: Int? = nil) {
        self.minChars = minChars
        self.maxChars = maxChars
        self.textChunkLimit = textChunkLimit
        self.maxLines = maxLines
    }

    /// Effective high bound after clamping to the surface hard cap.
    public var effectiveMaxChars: Int {
        min(maxChars, textChunkLimit)
    }
}

public struct CoalescingConfig: Sendable, Equatable, Hashable {
    public var enabled: Bool
    public var idleMs: Int
    public var minChars: Int

    public init(enabled: Bool = false, idleMs: Int = 500, minChars: Int = 100) {
        self.enabled = enabled
        self.idleMs = idleMs
        self.minChars = minChars
    }
}

public enum PacingMode: Sendable, Equatable, Hashable {
    case off
    case natural
    case custom(minMs: Int, maxMs: Int)
}

public struct PacingConfig: Sendable, Equatable, Hashable {
    public var mode: PacingMode

    public init(mode: PacingMode = .off) {
        self.mode = mode
    }
}

/// Capability-typed streaming configuration for a surface attachment.
public struct StreamingSurfaceCapabilities: Sendable, Equatable, Hashable {
    public var granularity: StreamingGranularity
    public var supportedGranularities: Set<StreamingGranularity>
    public var blockStreaming: BlockStreamingConfig
    public var previewMode: PreviewMode
    public var supportedPreviewModes: Set<PreviewMode>
    public var chunker: ChunkerConfig
    public var coalescing: CoalescingConfig
    public var pacing: PacingConfig
    public var breakPreference: BreakPreference
    public var cancellationMarker: String

    public init(
        granularity: StreamingGranularity,
        supportedGranularities: Set<StreamingGranularity>,
        blockStreaming: BlockStreamingConfig = BlockStreamingConfig(),
        previewMode: PreviewMode = .off,
        supportedPreviewModes: Set<PreviewMode> = [.off, .partial],
        chunker: ChunkerConfig = ChunkerConfig(),
        coalescing: CoalescingConfig = CoalescingConfig(),
        pacing: PacingConfig = PacingConfig(),
        breakPreference: BreakPreference = .paragraph,
        cancellationMarker: String = "_(cancelled)_"
    ) {
        self.granularity = granularity
        self.supportedGranularities = supportedGranularities
        self.blockStreaming = blockStreaming
        self.previewMode = previewMode
        self.supportedPreviewModes = supportedPreviewModes
        self.chunker = chunker
        self.coalescing = coalescing
        self.pacing = pacing
        self.breakPreference = breakPreference
        self.cancellationMarker = cancellationMarker
    }

    /// Resolves the effective preview mode, degrading unsupported modes gracefully.
    public var effectivePreviewMode: PreviewMode {
        let requested = previewMode
        if supportedPreviewModes.contains(requested) {
            return requested
        }
        if requested == .progress, supportedPreviewModes.contains(.partial) {
            return .partial
        }
        if supportedPreviewModes.contains(.off) {
            return .off
        }
        return supportedPreviewModes.sorted(by: { $0.rawValue < $1.rawValue }).first ?? .off
    }

    /// Whether block streaming is active for this turn (explicitly on at block rung or higher).
    public var usesBlockStreaming: Bool {
        blockStreaming.enabled && granularity == .block
    }

    /// Whether preview streaming is active (mutually exclusive with block streaming per turn).
    public var usesPreviewStreaming: Bool {
        !usesBlockStreaming && granularity == .previewEdit && effectivePreviewMode != .off
    }

    /// Whether block streaming surfaces ephemeral tool-progress lines during tool-heavy turns.
    public var surfacesToolProgressInBlockMode: Bool {
        granularity == .block && blockStreaming.enabled && supportedPreviewModes.contains(.progress)
    }

    // MARK: - Presets

    public static let terminal = StreamingSurfaceCapabilities(
        granularity: .tokenDelta,
        supportedGranularities: [.tokenDelta, .finalOnly],
        blockStreaming: BlockStreamingConfig(enabled: false),
        previewMode: .off,
        coalescing: CoalescingConfig(enabled: false),
        pacing: PacingConfig(mode: .off)
    )

    public static let socialChannel = StreamingSurfaceCapabilities(
        granularity: .block,
        supportedGranularities: [.block, .previewEdit, .finalOnly],
        blockStreaming: BlockStreamingConfig(enabled: true, breakBoundary: .textEnd),
        previewMode: .off,
        supportedPreviewModes: [.off, .partial, .progress],
        chunker: ChunkerConfig(minChars: 400, maxChars: 2000, textChunkLimit: 4000),
        coalescing: CoalescingConfig(enabled: true, idleMs: 600, minChars: 200),
        pacing: PacingConfig(mode: .natural),
        breakPreference: .paragraph
    )

    public static let operatorChannel = StreamingSurfaceCapabilities(
        granularity: .block,
        supportedGranularities: [.block, .previewEdit, .finalOnly],
        blockStreaming: BlockStreamingConfig(enabled: true, breakBoundary: .textEnd),
        previewMode: .off,
        chunker: ChunkerConfig(minChars: 200, maxChars: 2000, textChunkLimit: 4000),
        coalescing: CoalescingConfig(enabled: false),
        pacing: PacingConfig(mode: .off),
        breakPreference: .paragraph
    )

    public static let finalOnly = StreamingSurfaceCapabilities(
        granularity: .finalOnly,
        supportedGranularities: [.finalOnly],
        blockStreaming: BlockStreamingConfig(enabled: false),
        previewMode: .off,
        coalescing: CoalescingConfig(enabled: false),
        pacing: PacingConfig(mode: .off)
    )
}
