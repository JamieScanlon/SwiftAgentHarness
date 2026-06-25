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

/// A portable presentation block. An approval request is just a sequence of these
/// blocks, so it rides the same outbound path as any other message: render natively
/// where possible, degrade to text everywhere else.
public enum ApprovalBlock: Codable, Sendable, Equatable {
    case text(String)
    case context(String)
    case buttons([ApprovalButton])

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case buttons
    }

    private enum BlockType: String, Codable {
        case text
        case context
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
            case .buttons:
                break
            }
        }
        lines.append("Reply `/approve \(approvalID)` to allow (add `always` to remember), or `/deny \(approvalID)` to reject.")
        return lines.joined(separator: "\n")
    }
}
