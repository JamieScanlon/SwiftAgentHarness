import Foundation

public enum SlashCommandSource: String, Sendable, Equatable {
    case builtin
    case plugin
    case skill
    case mcp
    case user
}

public struct SlashCommandBase: Sendable, Equatable {
    public var name: String
    public var aliases: [String]
    public var description: String
    public var argumentHint: String?
    /// Space-separated terms for fuzzy autocomplete matching; not shown as the primary label.
    public var hiddenKeywords: String
    public var isHidden: Bool
    public var source: SlashCommandSource
    public var category: SlashCommandCategory
    public var ownerOnly: Bool
    public var bypassTier: SlashCommandBypassTier
    public var isEnabled: Bool

    public init(
        name: String,
        aliases: [String] = [],
        description: String,
        argumentHint: String? = nil,
        hiddenKeywords: String = "",
        isHidden: Bool = false,
        source: SlashCommandSource = .builtin,
        category: SlashCommandCategory = .command,
        ownerOnly: Bool = false,
        bypassTier: SlashCommandBypassTier = .queued,
        isEnabled: Bool = true
    ) {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.argumentHint = argumentHint
        self.hiddenKeywords = hiddenKeywords
        self.isHidden = isHidden
        self.source = source
        self.category = category
        self.ownerOnly = ownerOnly
        self.bypassTier = bypassTier
        self.isEnabled = isEnabled
    }
}

public struct SlashPromptConfiguration: Sendable, Equatable {
    public var allowedTools: [String]
    public var model: String?
    public var effort: String?

    public init(
        allowedTools: [String] = [],
        model: String? = nil,
        effort: String? = nil
    ) {
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
    }
}

public enum SlashToolDispatchArgMode: String, Sendable, Equatable {
    case raw
    case parsed
}

public enum SlashCommandKind: Sendable, Equatable {
    case local
    case prompt(SlashPromptConfiguration)
    case directive
    case toolDispatch(toolName: String, argMode: SlashToolDispatchArgMode)
}

public struct SlashCommand: Sendable, Equatable {
    public var base: SlashCommandBase
    public var kind: SlashCommandKind

    public init(base: SlashCommandBase, kind: SlashCommandKind) {
        self.base = base
        self.kind = kind
    }
}

public struct ParsedSlashCommand: Sendable, Equatable {
    public var name: String
    public var args: String

    public init(name: String, args: String) {
        self.name = name
        self.args = args
    }
}

public enum SlashCommandDispatchResult: Sendable, Equatable {
    case passthrough
    case unknown(ParsedSlashCommand)
    case disabled(SlashCommand, ParsedSlashCommand)
    case unauthorized(SlashCommand, ParsedSlashCommand)
    case local(SlashCommand, ParsedSlashCommand)
    case prompt(SlashCommand, ParsedSlashCommand)
    case directive(SlashCommand, ParsedSlashCommand)
    case toolDispatch(SlashCommand, ParsedSlashCommand)
}
