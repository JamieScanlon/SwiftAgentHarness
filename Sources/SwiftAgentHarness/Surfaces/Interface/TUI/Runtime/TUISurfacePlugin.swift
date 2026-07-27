import Foundation

/// The terminal surface's plugin record.
///
/// Satisfies the same ``SurfacePlugin`` contract as the channel surface. Threading and
/// heartbeat are absent rather than stubbed: a terminal has one conversation on screen and
/// no typing indicator to send, and declaring capabilities it doesn't have is how a shared
/// contract turns into a lowest-common-denominator one.
public struct TUISurfacePlugin: SurfacePlugin {
    public let surfaceID: String
    public let surfaceMeta: SurfaceMeta
    public let surfaceCapabilities: SurfaceCapabilities
    public let presentationRenderer: any SurfacePresentationRendering
    public let surfaceMessageToolDescriptor: (any SurfaceMessageToolDescribing)?
    public let streamingCapabilities: StreamingSurfaceCapabilities

    public init(
        surfaceID: String = InteractiveSurfaceID.tui,
        surfaceMeta: SurfaceMeta = SurfaceMeta(displayName: "Terminal", kindRaw: "tui"),
        surfaceCapabilities: SurfaceCapabilities = .terminal,
        presentationRenderer: any SurfacePresentationRendering = TUIPresentationRenderer(),
        surfaceMessageToolDescriptor: (any SurfaceMessageToolDescribing)? = nil,
        streamingCapabilities: StreamingSurfaceCapabilities = .terminal
    ) {
        self.surfaceID = surfaceID
        self.surfaceMeta = surfaceMeta
        self.surfaceCapabilities = surfaceCapabilities
        self.presentationRenderer = presentationRenderer
        self.surfaceMessageToolDescriptor = surfaceMessageToolDescriptor
        self.streamingCapabilities = streamingCapabilities
    }
}

public extension SurfaceCapabilities {
    /// The terminal sits at the top of the streaming ladder and renders every portable
    /// block type except `select`, but has no threading, no typing indicator and no
    /// platform media pipeline.
    static let terminal = SurfaceCapabilities(
        richPresentation: true,
        nativeApprovalCards: true,
        tokenStreaming: true,
        blockStreaming: false,
        previewStreaming: false,
        mediaAttachments: false,
        threading: false,
        typingIndicators: false
    )
}

/// Routes committed `message`-tool output for TUI-originated turns into the transcript.
///
/// Without a registered deliverer, `MessageOutputDeliveryRegistry.deliver` returns silently
/// for `originSurface == "tui"` and the rich presentation is dropped — only the tool
/// result's text fallback survives, so every structured message degraded to plain text on
/// a surface perfectly capable of rendering it.
public struct TUIMessageOutputDeliverer: MessageOutputDelivering {
    private let app: TUIApp
    private let conversationID: UUID?

    /// - Parameter conversationID: When set, deliveries for other conversations are
    ///   ignored — a terminal shows one conversation at a time.
    public init(app: TUIApp, conversationID: UUID? = nil) {
        self.app = app
        self.conversationID = conversationID
    }

    public func deliver(
        presentation: MessagePresentation,
        conversationID: UUID,
        metadata: MessageOutputDeliveryMetadata
    ) async {
        if let expected = self.conversationID, expected != conversationID { return }
        await app.deliver(presentation: presentation)
    }
}

/// Registers and unregisters the terminal surface with the core registries.
///
/// Registration is explicit and reversible because `MessageOutputDeliveryRegistry.shared`
/// is process-global and holds the deliverer — and therefore the app — until released.
public struct TUISurfaceRegistration: Sendable {
    public let plugin: TUISurfacePlugin

    public init(plugin: TUISurfacePlugin = TUISurfacePlugin()) {
        self.plugin = plugin
    }

    public func register(app: TUIApp, conversationID: UUID? = nil) async {
        await MessageOutputDeliveryRegistry.shared.register(
            surfaceID: plugin.surfaceID,
            deliverer: TUIMessageOutputDeliverer(app: app, conversationID: conversationID)
        )
        // Deliberately NOT registering `surfaceMessageToolDescriptor` here.
        // `MessageToolSchemaRegistry.register(actionSchemas:)` replaces the whole list
        // rather than merging, and `ChannelListenerRegistry` sets the union of every
        // channel's media params — so registering from a second surface would silently
        // wipe them. Wire this up once the registry is keyed by surface.
    }

    public func unregister() async {
        await MessageOutputDeliveryRegistry.shared.unregister(surfaceID: plugin.surfaceID)
    }
}
