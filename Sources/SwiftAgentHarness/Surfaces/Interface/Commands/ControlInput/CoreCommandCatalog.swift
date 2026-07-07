import Foundation

/// Baseline slash-command catalog from the interface spec.
public enum CoreCommandCatalog {
    public static func baselineCommands(compactEnabled: Bool) -> [SlashCommand] {
        [
            sessionLifecycle(compactEnabled: compactEnabled),
            stateVisibility,
            turnTuning,
            decisionsControl,
        ].flatMap { $0 }
    }

    public static func registry(compactEnabled: Bool, additional: [SlashCommand] = []) -> SlashCommandRegistry {
        let merged = mergeReplacingByName(baselineCommands(compactEnabled: compactEnabled) + additional)
        return SlashCommandRegistry(commands: merged)
    }

    private static func mergeReplacingByName(_ commands: [SlashCommand]) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        for command in commands {
            byName[normalizeKey(command.base.name)] = command
        }
        return Array(byName.values).sorted { $0.base.name < $1.base.name }
    }

    private static func normalizeKey(_ name: String) -> String {
        SlashCommandRegistry.normalizeKey(name)
    }

    // MARK: - Groups

    private static func sessionLifecycle(compactEnabled: Bool) -> [SlashCommand] {
        [
            row(
                name: "new",
                description: "Start a new session.",
                argumentHint: "[model]",
                hiddenKeywords: "reset session start",
                category: .command,
                bypassTier: .always,
                kind: .local
            ),
            row(
                name: "reset",
                description: "Reset the current session.",
                hiddenKeywords: "clear restart",
                category: .command,
                bypassTier: .always,
                kind: .local
            ),
            row(
                name: "compact",
                description: "Compact the current conversation context.",
                argumentHint: "[instructions]",
                hiddenKeywords: "shrink context summarize",
                category: .command,
                bypassTier: .queued,
                kind: .local,
                isEnabled: compactEnabled
            ),
            row(
                name: "stop",
                description: "Stop the current generation.",
                hiddenKeywords: "cancel abort halt",
                category: .command,
                bypassTier: .always,
                kind: .local
            ),
        ]
    }

    private static var stateVisibility: [SlashCommand] {
        [
            row(
                name: "status",
                description: "Show session status.",
                hiddenKeywords: "state health",
                category: .inlineShortcut,
                bypassTier: .immediateUI,
                kind: .local
            ),
            row(
                name: "usage",
                description: "Show token and usage statistics.",
                hiddenKeywords: "tokens cost billing",
                category: .command,
                bypassTier: .sideEffectFree,
                kind: .local
            ),
            row(
                name: "context",
                description: "Show context window usage.",
                hiddenKeywords: "window tokens",
                category: .command,
                bypassTier: .sideEffectFree,
                kind: .local
            ),
            row(
                name: "tools",
                description: "List available tools.",
                hiddenKeywords: "tool registry",
                category: .command,
                bypassTier: .sideEffectFree,
                kind: .local
            ),
            row(
                name: "help",
                description: "Show essential slash commands.",
                hiddenKeywords: "commands usage",
                category: .inlineShortcut,
                bypassTier: .immediateUI,
                kind: .local
            ),
            row(
                name: "commands",
                description: "List all registered slash commands.",
                hiddenKeywords: "registry index",
                category: .inlineShortcut,
                bypassTier: .sideEffectFree,
                kind: .local
            ),
            row(
                name: "whoami",
                description: "Show the current sender identity.",
                hiddenKeywords: "identity sender user",
                category: .inlineShortcut,
                bypassTier: .immediateUI,
                kind: .local
            ),
        ]
    }

    private static var turnTuning: [SlashCommand] {
        [
            row(
                name: "think",
                description: "Set thinking level for this turn or session.",
                argumentHint: "<level>",
                hiddenKeywords: "thinking reasoning depth",
                category: .directive,
                bypassTier: .immediateUI,
                kind: .directive
            ),
            row(
                name: "model",
                description: "Select model for this turn or session.",
                argumentHint: "[name]",
                hiddenKeywords: "switch llm provider",
                category: .directive,
                bypassTier: .immediateUI,
                kind: .directive,
                ownerOnly: true
            ),
            row(
                name: "verbose",
                description: "Toggle verbose output for this turn or session.",
                hiddenKeywords: "debug detail logs",
                category: .directive,
                bypassTier: .immediateUI,
                kind: .directive
            ),
            row(
                name: "reasoning",
                description: "Set reasoning effort for this turn or session.",
                argumentHint: "<level>",
                hiddenKeywords: "think depth",
                category: .directive,
                bypassTier: .immediateUI,
                kind: .directive
            ),
        ]
    }

    private static var decisionsControl: [SlashCommand] {
        [
            row(
                name: "approve",
                description: "Approve a pending exec request by ID.",
                argumentHint: "<id> <decision>",
                hiddenKeywords: "exec approval allow",
                category: .command,
                bypassTier: .always,
                kind: .local
            ),
            row(
                name: "deny",
                description: "Deny a pending exec request by ID.",
                argumentHint: "<approval-id> [reason]",
                hiddenKeywords: "exec approval reject refuse",
                category: .command,
                bypassTier: .always,
                kind: .local
            ),
            row(
                name: "agents",
                description: "List active sub-agents.",
                hiddenKeywords: "subagent pool",
                category: .command,
                bypassTier: .sideEffectFree,
                kind: .local
            ),
        ]
    }

    private static func row(
        name: String,
        description: String,
        argumentHint: String? = nil,
        hiddenKeywords: String = "",
        category: SlashCommandCategory,
        bypassTier: SlashCommandBypassTier,
        kind: SlashCommandKind,
        ownerOnly: Bool = false,
        isEnabled: Bool = true
    ) -> SlashCommand {
        SlashCommand(
            base: SlashCommandBase(
                name: name,
                description: description,
                argumentHint: argumentHint,
                hiddenKeywords: hiddenKeywords,
                category: category,
                ownerOnly: ownerOnly,
                bypassTier: bypassTier,
                isEnabled: isEnabled
            ),
            kind: kind
        )
    }
}
