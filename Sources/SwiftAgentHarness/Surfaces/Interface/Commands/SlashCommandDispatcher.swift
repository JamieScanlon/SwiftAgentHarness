import Foundation

public struct SlashCommandRuntimeConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var allowUnknownPassthrough: Bool
    public var compactEnabled: Bool
    public var skillSlashEnabled: Bool
    public var directivesEnabled: Bool
    public var inlineShortcutsEnabled: Bool
    public var ownerOnlyDirectiveNames: Set<String>

    public init(
        enabled: Bool = true,
        allowUnknownPassthrough: Bool = true,
        compactEnabled: Bool = true,
        skillSlashEnabled: Bool = true,
        directivesEnabled: Bool = true,
        inlineShortcutsEnabled: Bool = true,
        ownerOnlyDirectiveNames: Set<String> = ["model"]
    ) {
        self.enabled = enabled
        self.allowUnknownPassthrough = allowUnknownPassthrough
        self.compactEnabled = compactEnabled
        self.skillSlashEnabled = skillSlashEnabled
        self.directivesEnabled = directivesEnabled
        self.inlineShortcutsEnabled = inlineShortcutsEnabled
        self.ownerOnlyDirectiveNames = ownerOnlyDirectiveNames
    }
}

public enum ParsedSlashInput: Sendable, Equatable {
    case builtin(ParsedSlashCommand)
    case skill(skillName: String, args: String)
}

public struct SlashCommandParser {
    public init() {}

    /// Parses `/skill:<name>` (case-insensitive prefix) separately from generic `/cmd` forms.
    public func parseInput(_ input: String) -> ParsedSlashInput? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        if let skillRange = trimmed.range(of: "/skill:", options: .caseInsensitive) {
            let after = String(trimmed[skillRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !after.isEmpty else { return nil }
            let parts = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let rawName = String(parts[0])
            guard !rawName.isEmpty else { return nil }
            let skillName = rawName.lowercased()
            let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return .skill(skillName: skillName, args: args)
        }
        guard let builtin = parse(input) else { return nil }
        return .builtin(builtin)
    }

    /// Parses command-only messages that start with `/`.
    /// Supports `/name args` and `/name:args`.
    public func parse(_ input: String) -> ParsedSlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        guard !body.isEmpty else { return nil }

        let splitIndex = body.firstIndex(where: { $0.isWhitespace || $0 == ":" })
        let name: String
        let args: String

        if let splitIndex {
            name = String(body[..<splitIndex]).lowercased()
            args = String(body[body.index(after: splitIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = String(body).lowercased()
            args = ""
        }
        guard !name.isEmpty else { return nil }
        return ParsedSlashCommand(name: name, args: args)
    }
}

public struct SlashCommandRegistry: Sendable {
    public let commands: [SlashCommand]
    private let commandByName: [String: SlashCommand]

    public init(commands: [SlashCommand]) {
        self.commands = commands
        var map: [String: SlashCommand] = [:]
        for command in commands {
            map[Self.normalizeKey(command.base.name)] = command
            for alias in command.base.aliases {
                map[Self.normalizeKey(alias)] = command
            }
        }
        self.commandByName = map
    }

    static func normalizeKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("/") { t.removeFirst() }
        return t
    }

    public func resolve(_ name: String) -> SlashCommand? {
        commandByName[Self.normalizeKey(name)]
    }

    /// Autocomplete rows; set `includeHidden` to surface debug-only commands.
    public func autocompleteEntries(includeHidden: Bool = false) -> [SlashCommandAutocompleteEntry] {
        commands.compactMap { cmd in
            guard includeHidden || !cmd.base.isHidden else { return nil }
            let display = "/" + Self.normalizeKey(cmd.base.name)
            return SlashCommandAutocompleteEntry(
                name: display,
                description: cmd.base.description,
                argumentHint: cmd.base.argumentHint,
                hiddenKeywords: cmd.base.hiddenKeywords,
                bypassTier: cmd.base.bypassTier
            )
        }
    }

    public func commandNames(for tier: SlashCommandBypassTier) -> Set<String> {
        var names = Set<String>()
        for command in commands where command.base.bypassTier == tier {
            names.insert(Self.normalizeKey(command.base.name))
            for alias in command.base.aliases {
                names.insert(Self.normalizeKey(alias))
            }
        }
        return names
    }

    public func allClassifiedCommandNames(extraHiddenDebugNames: Set<String> = []) -> Set<String> {
        var all = Set<String>()
        for tier in SlashCommandBypassTier.allCases {
            all.formUnion(commandNames(for: tier))
        }
        all.formUnion(extraHiddenDebugNames.map { Self.normalizeKey($0) })
        return all
    }

    public static func builtins(compactEnabled: Bool) -> SlashCommandRegistry {
        let extensions: [SlashCommand] = [
            SlashCommand(
                base: SlashCommandBase(
                    name: "memory",
                    description: "Request the client to open a memory file for editing.",
                    argumentHint: "[filename]",
                    hiddenKeywords: "edit remember persistent",
                    bypassTier: .queued
                ),
                kind: .local
            ),
            SlashCommand(
                base: SlashCommandBase(
                    name: "dreaming",
                    description: "Show or toggle background memory consolidation (dreaming).",
                    argumentHint: "status|explain|on|off",
                    hiddenKeywords: "dream consolidate recall cron",
                    bypassTier: .queued
                ),
                kind: .local
            ),
            SlashCommand(
                base: SlashCommandBase(
                    name: "active-memory",
                    description: "Show or toggle pre-reply active memory (session or --global).",
                    argumentHint: "status|on|off [--global]",
                    hiddenKeywords: "recall pre-reply memory toggle",
                    bypassTier: .queued
                ),
                kind: .local
            ),
            SlashCommand(
                base: SlashCommandBase(
                    name: "init",
                    description: "Bootstrap AGENTS.md for the current workspace.",
                    argumentHint: "",
                    hiddenKeywords: "bootstrap agents claude project",
                    bypassTier: .queued
                ),
                kind: .local
            ),
        ]
        return CoreCommandCatalog.registry(compactEnabled: compactEnabled, additional: extensions)
    }

    /// Built-in commands plus one registry row per eligible skill (`name` key `skill:<lowercased>`).
    public static func merged(
        compactEnabled: Bool,
        skills: [AvailableSkillInfo],
        excludedSkillAutocompleteNames: Set<String>
    ) -> SlashCommandRegistry {
        let base = builtins(compactEnabled: compactEnabled).commands
        let excluded = Set(excludedSkillAutocompleteNames.map { $0.lowercased() })
        let skillCommands: [SlashCommand] = skills.compactMap { info in
            let key = info.name.lowercased()
            guard !excluded.contains(key) else { return nil }
            let registryName = "skill:\(key)"
            return SlashCommand(
                base: SlashCommandBase(
                    name: registryName,
                    description: info.description,
                    hiddenKeywords: info.name,
                    source: .skill,
                    bypassTier: .queued,
                    isEnabled: true
                ),
                kind: .local
            )
        }
        return SlashCommandRegistry(commands: base + skillCommands)
    }
}

public struct SlashCommandDispatcher {
    private let parser: SlashCommandParser
    private let registry: SlashCommandRegistry

    public init(
        parser: SlashCommandParser = SlashCommandParser(),
        registry: SlashCommandRegistry
    ) {
        self.parser = parser
        self.registry = registry
    }

    public func dispatch(
        input: String,
        runtimeConfig: SlashCommandRuntimeConfiguration,
        isOwner: Bool = true
    ) -> SlashCommandDispatchResult {
        guard runtimeConfig.enabled else { return .passthrough }
        guard let parsedInput = parser.parseInput(input) else { return .passthrough }
        switch parsedInput {
        case .skill:
            return .passthrough
        case .builtin(let parsed):
            return dispatchBuiltin(parsed: parsed, runtimeConfig: runtimeConfig, isOwner: isOwner)
        }
    }

    public func dispatchBuiltin(
        parsed: ParsedSlashCommand,
        runtimeConfig: SlashCommandRuntimeConfiguration,
        isOwner: Bool = true
    ) -> SlashCommandDispatchResult {
        guard runtimeConfig.enabled else { return .passthrough }
        guard let command = registry.resolve(parsed.name) else {
            return runtimeConfig.allowUnknownPassthrough ? .passthrough : .unknown(parsed)
        }
        guard command.base.source != .skill else {
            return .passthrough
        }
        guard command.base.isEnabled else {
            return runtimeConfig.allowUnknownPassthrough ? .passthrough : .disabled(command, parsed)
        }
        guard !command.base.ownerOnly || isOwner else {
            return .unauthorized(command, parsed)
        }

        switch command.kind {
        case .local:
            return .local(command, parsed)
        case .prompt:
            return .prompt(command, parsed)
        case .directive:
            return .directive(command, parsed)
        case .toolDispatch:
            return .toolDispatch(command, parsed)
        }
    }
}
