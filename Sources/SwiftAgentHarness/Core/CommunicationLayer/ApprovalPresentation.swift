import Foundation

/// Visual emphasis hint for an approval button. Surfaces map this to a native
/// affordance (Slack `style`, a terminal accent, etc.) or ignore it for a text
/// fallback.
public enum ApprovalButtonStyle: String, Codable, Sendable, Equatable {
    case `default`
    case primary
    case danger
}

/// A single selectable choice on an approval request. `id` is the surface-agnostic
/// decision token that maps onto an `ApprovalDecision`; `label` is the human text.
public struct ApprovalButton: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var style: ApprovalButtonStyle

    public init(id: String, label: String, style: ApprovalButtonStyle = .default) {
        self.id = id
        self.label = label
        self.style = style
    }

    /// Plan-exit approval choices: approve once or request revision (deny). No allow-always.
    public static func planExitDecisionButtons() -> [ApprovalButton] {
        [
            ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Approve", style: .primary),
            ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Request revision", style: .danger),
        ]
    }

    /// The canonical allow-once / allow-always / deny button set every approval
    /// uses unless a classifier supplies its own choices.
    public static func standardDecisionButtons() -> [ApprovalButton] {
        [
            ApprovalButton(id: ApprovalDecision.allowOnce.rawValue, label: "Allow once"),
            ApprovalButton(id: ApprovalDecision.allowAlways.rawValue, label: "Always allow", style: .primary),
            ApprovalButton(id: ApprovalDecision.deny.rawValue, label: "Deny", style: .danger),
        ]
    }
}

/// An image a surface can show inline, such as the region an action lands on. `ref` names the bytes: a
/// `blob://` reference a surface fetches, or a `data:` URL where there is no blob store. `alt` is required and must
/// carry the decision-relevant facts on its own, since surfaces that can't show images render only it.
public struct PresentationImage: Codable, Sendable, Equatable {
    public var ref: String
    public var alt: String
    public var mime: String?
    public var width: Int?
    public var height: Int?

    public init(ref: String, alt: String, mime: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.ref = ref
        self.alt = alt
        self.mime = mime
        self.width = width
        self.height = height
    }

    /// An image carried inline as a `data:` URL.
    public init(data: Data, mime: String, width: Int? = nil, height: Int? = nil, alt: String) {
        self.init(ref: "data:\(mime);base64,\(data.base64EncodedString())", alt: alt, mime: mime, width: width, height: height)
    }

    /// The bytes of a `data:` URL ref; `nil` for a blob ref, which a surface fetches.
    public var inlineData: Data? {
        guard ref.hasPrefix("data:"), let comma = ref.firstIndex(of: ","),
              ref[ref.startIndex..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(ref[ref.index(after: comma)...]))
    }

    /// The line surfaces show in its place.
    public var textFallback: String { "[Image: \(alt)]" }

    enum CodingKeys: String, CodingKey {
        case ref, alt, mime, width, height
    }

    /// Reads the image's fields from the block that carries them, which keeps them beside its `type`.
    init(fieldsOf decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ref: try container.decode(String.self, forKey: .ref),
            alt: try container.decode(String.self, forKey: .alt),
            mime: try container.decodeIfPresent(String.self, forKey: .mime),
            width: try container.decodeIfPresent(Int.self, forKey: .width),
            height: try container.decodeIfPresent(Int.self, forKey: .height)
        )
    }

    func encodeFields(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(alt, forKey: .alt)
        try container.encodeIfPresent(mime, forKey: .mime)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
    }
}

/// A portable presentation block. An approval request is just a sequence of these
/// blocks, so it rides the same outbound path as any other message: render natively
/// where possible, degrade to text everywhere else.
public enum ApprovalBlock: Codable, Sendable, Equatable {
    case text(String)
    case context(String)
    case image(PresentationImage)
    case buttons([ApprovalButton])

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
        case buttons
    }

    private enum BlockType: String, Codable {
        case text
        case context
        case image
        case buttons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .context:
            self = .context(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(try PresentationImage(fieldsOf: decoder))
        case .buttons:
            self = .buttons(try container.decode([ApprovalButton].self, forKey: .buttons))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .context(let value):
            try container.encode(BlockType.context, forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let image):
            try container.encode(BlockType.image, forKey: .type)
            try image.encodeFields(to: encoder)
        case .buttons(let buttons):
            try container.encode(BlockType.buttons, forKey: .type)
            try container.encode(buttons, forKey: .buttons)
        }
    }
}

/// The surface-agnostic shape of an approval request. A classifier describes the
/// approval once as a sequence of blocks (the rich justification plus the choices);
/// every surface renders the same presentation as the best control it can offer.
public struct ApprovalPresentation: Codable, Sendable, Equatable {
    public var blocks: [ApprovalBlock]

    public init(blocks: [ApprovalBlock]) {
        self.blocks = blocks
    }

    /// The buttons declared on this presentation, flattened across button blocks.
    public var buttons: [ApprovalButton] {
        blocks.flatMap { block -> [ApprovalButton] in
            if case .buttons(let buttons) = block { return buttons }
            return []
        }
    }

    /// Builds a standard approval presentation: a title line, optional context
    /// blocks (the rich justification), and the canonical decision buttons unless
    /// custom choices are supplied. Empty context strings are skipped.
    public static func standard(
        title: String,
        context: [String] = [],
        buttons: [ApprovalButton] = ApprovalButton.standardDecisionButtons()
    ) -> ApprovalPresentation {
        var blocks: [ApprovalBlock] = [.text(title)]
        for line in context where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.context(line))
        }
        blocks.append(.buttons(buttons))
        return ApprovalPresentation(blocks: blocks)
    }

    /// Conservative text rendering used as the universal fallback for any surface
    /// that can't render native controls. Includes the rich justification and the
    /// `/approve` and `/deny` recovery commands.
    public func textFallback(approvalID: String) -> String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .text(let value):
                lines.append(value)
            case .context(let value):
                lines.append(value)
            case .image(let image):
                lines.append(image.textFallback)
            case .buttons:
                break
            }
        }
        lines.append("Reply `/approve \(approvalID)` to allow (add `always` to remember), or `/deny \(approvalID)` to reject.")
        return lines.joined(separator: "\n")
    }
}
