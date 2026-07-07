import Foundation

/// Visual emphasis for portable message blocks.
public enum MessageTone: String, Codable, Sendable, Equatable {
    case info
    case success
    case warning
    case error
}

/// A selectable option in a portable `select` block.
public struct MessageSelectOption: Codable, Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A portable presentation block for agent output and approvals.
public enum MessageBlock: Codable, Sendable, Equatable {
    case text(String)
    case context(String)
    case divider
    case buttons([ApprovalButton])
    case select(options: [MessageSelectOption], label: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case buttons
        case options
        case label
    }

    private enum BlockType: String, Codable {
        case text
        case context
        case divider
        case buttons
        case select
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .context:
            self = .context(try container.decode(String.self, forKey: .text))
        case .divider:
            self = .divider
        case .buttons:
            self = .buttons(try container.decode([ApprovalButton].self, forKey: .buttons))
        case .select:
            self = .select(
                options: try container.decode([MessageSelectOption].self, forKey: .options),
                label: try container.decodeIfPresent(String.self, forKey: .label)
            )
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
        case .divider:
            try container.encode(BlockType.divider, forKey: .type)
        case .buttons(let buttons):
            try container.encode(BlockType.buttons, forKey: .type)
            try container.encode(buttons, forKey: .buttons)
        case .select(let options, let label):
            try container.encode(BlockType.select, forKey: .type)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(label, forKey: .label)
        }
    }
}

/// Portable agent output intent. Surfaces render natively; core degrades to conservative text.
public struct MessagePresentation: Codable, Sendable, Equatable {
    public var title: String?
    public var tone: MessageTone?
    public var blocks: [MessageBlock]

    public init(title: String? = nil, tone: MessageTone? = nil, blocks: [MessageBlock] = []) {
        self.title = title
        self.tone = tone
        self.blocks = blocks
    }

    public var buttons: [ApprovalButton] {
        blocks.flatMap { block -> [ApprovalButton] in
            if case .buttons(let buttons) = block { return buttons }
            return []
        }
    }

    /// Conservative text rendering for surfaces that cannot render rich blocks.
    public func textFallback() -> String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append(title)
        }
        for block in blocks {
            switch block {
            case .text(let value):
                lines.append(value)
            case .context(let value):
                lines.append(value)
            case .divider:
                lines.append("---")
            case .buttons(let buttons):
                let labels = buttons.map(\.label).joined(separator: " | ")
                if !labels.isEmpty {
                    lines.append(labels)
                }
            case .select(let options, let label):
                if let label, !label.isEmpty {
                    lines.append(label)
                }
                lines.append(options.map(\.label).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Maps approval presentations onto the shared portable vocabulary.
    public static func fromApproval(_ approval: ApprovalPresentation, title: String? = nil) -> MessagePresentation {
        let blocks = approval.blocks.map { block -> MessageBlock in
            switch block {
            case .text(let value): return .text(value)
            case .context(let value): return .context(value)
            case .buttons(let buttons): return .buttons(buttons)
            }
        }
        return MessagePresentation(title: title, blocks: blocks)
    }
}

extension ApprovalPresentation {
    public func asMessagePresentation(title: String? = nil) -> MessagePresentation {
        MessagePresentation.fromApproval(self, title: title)
    }
}
