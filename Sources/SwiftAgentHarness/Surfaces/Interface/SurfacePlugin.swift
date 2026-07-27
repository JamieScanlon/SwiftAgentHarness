import Foundation

// MARK: - Portable presentation vocabulary
//
// These types were originally introduced channel-first (`ChannelRenderedPayload`,
// `ChannelOutboundRichPresentation`, …), but nothing about them is channel-specific: they
// describe a *rendered portable presentation*, which is exactly what every surface
// produces. They are declared here and the channel names are kept as typealiases, so the
// channel surface compiles unchanged while the terminal surface reuses the same contract
// instead of growing a parallel one.

/// What a surface can render natively from a ``MessagePresentation``.
///
/// Anything unsupported degrades to the core-owned text fallback rather than being
/// dropped — the "text floor, native enhancement" rule from the interface spec.
public struct SurfacePresentationCapabilities: Sendable, Equatable {
    public var supported: Bool
    public var buttons: Bool
    public var selects: Bool
    public var context: Bool
    public var divider: Bool

    public init(supported: Bool, buttons: Bool, selects: Bool, context: Bool, divider: Bool) {
        self.supported = supported
        self.buttons = buttons
        self.selects = selects
        self.context = context
        self.divider = divider
    }

    public static let mockRich = SurfacePresentationCapabilities(
        supported: true,
        buttons: true,
        selects: false,
        context: true,
        divider: true
    )

    /// Text floor: no native block rendering at all.
    public static let textOnly = SurfacePresentationCapabilities(
        supported: false,
        buttons: false,
        selects: false,
        context: false,
        divider: false
    )
}

public struct SurfaceApprovalAction: Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct SurfaceApprovalCard: Sendable, Equatable {
    public var approvalID: String
    public var title: String
    public var command: String
    public var description: String
    public var actions: [SurfaceApprovalAction]

    public init(
        approvalID: String,
        title: String,
        command: String,
        description: String,
        actions: [SurfaceApprovalAction]
    ) {
        self.approvalID = approvalID
        self.title = title
        self.command = command
        self.description = description
        self.actions = actions
    }
}

public struct SurfaceRichPresentation: Sendable, Equatable {
    public var title: String?
    public var tone: MessageTone?
    public var blocks: [MessageBlock]

    public init(title: String? = nil, tone: MessageTone? = nil, blocks: [MessageBlock]) {
        self.title = title
        self.tone = tone
        self.blocks = blocks
    }
}

/// A presentation rendered for one surface: always a text floor, plus whatever native
/// structure that surface declared it could handle.
public struct SurfaceRenderedPayload: Sendable, Equatable {
    public var text: String
    public var richPresentation: SurfaceRichPresentation?
    public var approvalCard: SurfaceApprovalCard?

    public init(
        text: String,
        approvalCard: SurfaceApprovalCard? = nil,
        richPresentation: SurfaceRichPresentation? = nil
    ) {
        self.text = text
        self.approvalCard = approvalCard
        self.richPresentation = richPresentation
    }
}

// MARK: - Shared block filtering

/// Filters portable blocks down to what a surface declared it can render.
///
/// Shared rather than duplicated per surface: the degradation rule is a property of the
/// contract, not of any one surface.
public enum SurfacePresentationFilter {
    public static func nativeBlocks(
        from blocks: [MessageBlock],
        capabilities: SurfacePresentationCapabilities
    ) -> [MessageBlock] {
        blocks.compactMap { block in
            switch block {
            case .text:
                return block
            case .context:
                return capabilities.context ? block : nil
            case .divider:
                return capabilities.divider ? block : nil
            case .buttons:
                return capabilities.buttons ? block : nil
            case .select:
                return capabilities.selects ? block : nil
            }
        }
    }

    /// The standard render: text floor always, native structure only when the surface
    /// supports it and the presentation actually carries any.
    public static func render(
        _ presentation: MessagePresentation,
        capabilities: SurfacePresentationCapabilities
    ) -> SurfaceRenderedPayload {
        let fallback = presentation.textFallback()
        guard capabilities.supported else {
            return SurfaceRenderedPayload(text: fallback, approvalCard: nil)
        }
        let blocks = nativeBlocks(from: presentation.blocks, capabilities: capabilities)
        let hasRichContent = !blocks.isEmpty || presentation.title != nil || presentation.tone != nil
        guard hasRichContent else {
            return SurfaceRenderedPayload(text: fallback, approvalCard: nil)
        }
        return SurfaceRenderedPayload(
            text: fallback,
            approvalCard: nil,
            richPresentation: SurfaceRichPresentation(
                title: presentation.title,
                tone: presentation.tone,
                blocks: blocks
            )
        )
    }
}

// MARK: - Surface plugin contract

public struct SurfaceMeta: Sendable, Equatable {
    /// Human-readable identity of the concrete surface (platform name, "terminal", …).
    public var displayName: String
    /// Transport/kind discriminator, surface-defined.
    public var kindRaw: String

    public init(displayName: String, kindRaw: String) {
        self.displayName = displayName
        self.kindRaw = kindRaw
    }
}

/// Capability record shared by every surface.
///
/// Deliberately a *record*, not a class hierarchy: surfaces differ by which slots they
/// fill, and a record lets a surface declare "I do token streaming and native buttons but
/// not threading" without inheriting behaviour it has to stub out.
public struct SurfaceCapabilities: Sendable, Equatable, Codable {
    public var richPresentation: Bool
    public var nativeApprovalCards: Bool
    public var tokenStreaming: Bool
    public var blockStreaming: Bool
    public var previewStreaming: Bool
    public var mediaAttachments: Bool
    public var threading: Bool
    public var typingIndicators: Bool

    public init(
        richPresentation: Bool = false,
        nativeApprovalCards: Bool = false,
        tokenStreaming: Bool = false,
        blockStreaming: Bool = true,
        previewStreaming: Bool = false,
        mediaAttachments: Bool = false,
        threading: Bool = false,
        typingIndicators: Bool = false
    ) {
        self.richPresentation = richPresentation
        self.nativeApprovalCards = nativeApprovalCards
        self.tokenStreaming = tokenStreaming
        self.blockStreaming = blockStreaming
        self.previewStreaming = previewStreaming
        self.mediaAttachments = mediaAttachments
        self.threading = threading
        self.typingIndicators = typingIndicators
    }
}

/// Outbound slot every surface fills: turn a portable presentation into something this
/// surface can show. Delivery itself stays surface-specific — a channel needs a chat and
/// thread id, a terminal writes into its own transcript — so it is deliberately *not*
/// part of the shared contract.
public protocol SurfacePresentationRendering: Sendable {
    var presentationCapabilities: SurfacePresentationCapabilities { get }
    /// Maximum characters per outbound chunk. Surfaces without a wire limit report a
    /// large value rather than pretending to be unlimited.
    var textChunkLimit: Int { get }
    func renderPresentation(_ presentation: MessagePresentation) -> SurfaceRenderedPayload
}

/// Optional media params contributed to the shared `message` tool schema.
public protocol SurfaceMessageToolDescribing: Sendable {
    func describeMessageTool() -> [MessageToolActionSchema]
}

/// The uniform surface contract.
///
/// Both the channel surface and the terminal surface satisfy this. It carries only what is
/// genuinely common — identity, capabilities, presentation rendering, message-tool schema
/// contribution, streaming rung. Threading, heartbeat and platform delivery remain channel
/// extensions, because a terminal has no honest implementation of them and stubbing them
/// out is how a shared contract rots into a lowest-common-denominator one.
public protocol SurfacePlugin: Sendable {
    /// Matches the `originSurface` provenance value used for routing and trust.
    var surfaceID: String { get }
    var surfaceMeta: SurfaceMeta { get }
    var surfaceCapabilities: SurfaceCapabilities { get }
    var presentationRenderer: any SurfacePresentationRendering { get }
    var surfaceMessageToolDescriptor: (any SurfaceMessageToolDescribing)? { get }
    var streamingCapabilities: StreamingSurfaceCapabilities { get }
}

public extension SurfacePlugin {
    var surfaceMessageToolDescriptor: (any SurfaceMessageToolDescribing)? { nil }

    /// Convenience: render through this surface's declared capabilities.
    func render(_ presentation: MessagePresentation) -> SurfaceRenderedPayload {
        presentationRenderer.renderPresentation(presentation)
    }
}
