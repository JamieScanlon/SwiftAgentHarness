import Foundation

/// Portable inbound envelope produced by the terminal composer.
public struct ComposerSubmission: Sendable, Equatable {
    public var text: String
    public var attachments: [ComposerAttachment]
    public var provenance: ComposerProvenance

    public init(text: String, attachments: [ComposerAttachment] = [], provenance: ComposerProvenance = ComposerProvenance()) {
        self.text = text
        self.attachments = attachments
        self.provenance = provenance
    }
}

public struct ComposerAttachment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String
    public var path: String?

    public init(id: UUID = UUID(), kind: String, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
    }
}

public struct ComposerProvenance: Sendable, Equatable {
    public var originSurface: String
    public var inputTrustRaw: String?
    public var wasPasted: Bool
    public var pasteLineCount: Int

    public init(
        originSurface: String = "tui",
        inputTrustRaw: String? = nil,
        wasPasted: Bool = false,
        pasteLineCount: Int = 0
    ) {
        self.originSurface = originSurface
        self.inputTrustRaw = inputTrustRaw
        self.wasPasted = wasPasted
        self.pasteLineCount = pasteLineCount
    }
}
