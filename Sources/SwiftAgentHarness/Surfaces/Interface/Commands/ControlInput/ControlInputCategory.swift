import Foundation

/// Syntactic category for a slash token at the control-input boundary.
public enum SlashCommandCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case command
    case directive
    case inlineShortcut
}

/// Classification result produced before the model runs.
public enum ControlInputClassification: Sendable, Equatable {
    /// Whole message is a command; the model does not run this turn.
    case command(SlashCommand, ParsedSlashCommand)
    /// Message contains only directives; persist session settings and acknowledge.
    case directiveOnly([AppliedDirective])
    /// Directives tune this turn only; stripped prose continues to the model.
    case inlineHint(directives: [AppliedDirective], prose: String)
    /// Inline shortcut runs immediately; remaining prose continues to the model.
    case inlineShortcut(shortcuts: [InlineShortcutInvocation], remainingProse: String)
    /// No privileged control tokens recognized (or unauthorized fall-through).
    case plainText(String)
}

public struct ControlInputClassifierConfiguration: Sendable, Equatable {
    public var slashCommandsEnabled: Bool
    public var directivesEnabled: Bool
    public var inlineShortcutsEnabled: Bool
    public var allowUnknownPassthrough: Bool

    public init(
        slashCommandsEnabled: Bool = true,
        directivesEnabled: Bool = true,
        inlineShortcutsEnabled: Bool = true,
        allowUnknownPassthrough: Bool = true
    ) {
        self.slashCommandsEnabled = slashCommandsEnabled
        self.directivesEnabled = directivesEnabled
        self.inlineShortcutsEnabled = inlineShortcutsEnabled
        self.allowUnknownPassthrough = allowUnknownPassthrough
    }
}

public struct ControlInputTurnConfigurationPatch: Sendable, Equatable {
    public var turnThinkingOverride: ThinkingConfig?
    public var turnModelSlug: String?

    public init(
        turnThinkingOverride: ThinkingConfig? = nil,
        turnModelSlug: String? = nil
    ) {
        self.turnThinkingOverride = turnThinkingOverride
        self.turnModelSlug = turnModelSlug
    }
}
