import Foundation

/// Capability flags declared by a channel surface plugin.
public struct ChannelCapabilities: Sendable, Equatable, Codable {
    public var threading: Bool
    public var blockStreaming: Bool
    public var previewStreaming: Bool
    public var nativeApprovalCards: Bool
    public var typingIndicators: Bool
    public var reactions: Bool
    public var mediaAttachments: Bool

    public init(
        threading: Bool = false,
        blockStreaming: Bool = true,
        previewStreaming: Bool = false,
        nativeApprovalCards: Bool = false,
        typingIndicators: Bool = false,
        reactions: Bool = false,
        mediaAttachments: Bool = false
    ) {
        self.threading = threading
        self.blockStreaming = blockStreaming
        self.previewStreaming = previewStreaming
        self.nativeApprovalCards = nativeApprovalCards
        self.typingIndicators = typingIndicators
        self.reactions = reactions
        self.mediaAttachments = mediaAttachments
    }

    public static let mock = ChannelCapabilities(
        threading: true,
        blockStreaming: true,
        previewStreaming: true,
        nativeApprovalCards: true,
        typingIndicators: true
    )
}
