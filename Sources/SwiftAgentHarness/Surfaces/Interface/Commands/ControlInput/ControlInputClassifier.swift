import Foundation

/// Classifies inbound user input at the control-input boundary.
public struct ControlInputClassifier {
    private let parser: SlashCommandParser
    private let registry: SlashCommandRegistry
    private let capabilities: ControlSurfaceCapabilities
    private let configuration: ControlInputClassifierConfiguration

    public init(
        parser: SlashCommandParser = SlashCommandParser(),
        registry: SlashCommandRegistry,
        capabilities: ControlSurfaceCapabilities = .terminal,
        configuration: ControlInputClassifierConfiguration = ControlInputClassifierConfiguration()
    ) {
        self.parser = parser
        self.registry = registry
        self.capabilities = capabilities
        self.configuration = configuration
    }

    public func classify(
        input: String,
        authorization: ControlInputAuthorization = ControlInputAuthorization()
    ) -> ControlInputClassification {
        let original = input
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plainText(original) }
        guard configuration.slashCommandsEnabled, capabilities.effectiveTextCommandsEnabled else {
            return .plainText(original)
        }

        if containsPrivilegedTokens(in: trimmed) {
            if authorization.authorizeDirectives() == .fallThroughToPlainText {
                return .plainText(original)
            }
            if containsOwnerOnlyDirective(in: trimmed), !authorization.isOwner {
                return .plainText(original)
            }
        }

        if configuration.directivesEnabled, let directiveResult = classifyDirectives(in: trimmed, authorization: authorization) {
            return directiveResult
        }

        if configuration.inlineShortcutsEnabled, let shortcutResult = classifyInlineShortcut(in: trimmed, authorization: authorization) {
            return shortcutResult
        }

        if let commandResult = classifyWholeMessageCommand(in: trimmed, authorization: authorization) {
            return commandResult
        }

        if trimmed.hasPrefix("/"), !configuration.allowUnknownPassthrough {
            if let parsed = parser.parse(trimmed) {
                return .plainText(original)
            }
        }

        return .plainText(original)
    }

    public func turnConfigurationPatch(from directives: [AppliedDirective]) -> ControlInputTurnConfigurationPatch {
        var thinking: ThinkingConfig?
        var modelSlug: String?
        for directive in directives {
            if let config = directive.thinkingConfig {
                thinking = config
            }
            if let slug = directive.modelSlug {
                modelSlug = slug
            }
        }
        return ControlInputTurnConfigurationPatch(
            turnThinkingOverride: thinking,
            turnModelSlug: modelSlug
        )
    }

    // MARK: - Directives

    private func classifyDirectives(
        in trimmed: String,
        authorization: ControlInputAuthorization
    ) -> ControlInputClassification? {
        guard trimmed.hasPrefix("/") else { return nil }
        guard DirectiveCatalog.isDirective(firstTokenName(in: trimmed)) else { return nil }
        guard authorization.authorizeDirectives() == .allow else { return nil }

        var remaining = trimmed
        var directives: [AppliedDirective] = []

        while let next = remaining.firstNonWhitespacePrefix, next.hasPrefix("/") {
            guard let parsed = DirectiveCatalog.parseToken(from: remaining.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                break
            }
            guard DirectiveCatalog.isDirective(parsed.directive.kind.rawValue) else { break }
            directives.append(parsed.directive)
            remaining = String(remaining.dropFirst(parsed.consumed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !directives.isEmpty else { return nil }

        let prose = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if prose.isEmpty {
            let persisted = directives.map { AppliedDirective(kind: $0.kind, value: $0.value, scope: .sessionSetting) }
            return .directiveOnly(persisted)
        }

        let inline = directives.map { AppliedDirective(kind: $0.kind, value: $0.value, scope: .inlineHint) }
        return .inlineHint(directives: inline, prose: prose)
    }

    // MARK: - Inline shortcuts

    private func classifyInlineShortcut(
        in trimmed: String,
        authorization: ControlInputAuthorization
    ) -> ControlInputClassification? {
        guard let parsed = parser.parse(trimmed) else { return nil }
        guard InlineShortcutCatalog.isShortcut(parsed.name) else { return nil }
        guard !parsed.args.isEmpty else { return nil }
        guard authorization.authorizeShortcuts() == .allow else { return nil }
        guard let kind = InlineShortcutCatalog.kind(for: parsed.name) else { return nil }
        return .inlineShortcut(
            shortcuts: [InlineShortcutInvocation(kind: kind)],
            remainingProse: parsed.args
        )
    }

    // MARK: - Whole-message commands

    private func classifyWholeMessageCommand(
        in trimmed: String,
        authorization: ControlInputAuthorization
    ) -> ControlInputClassification? {
        guard trimmed.hasPrefix("/") else { return nil }

        if let skillInput = parser.parseInput(trimmed), case .skill = skillInput {
            return nil
        }

        guard let parsed = parser.parse(trimmed) else { return nil }

        if DirectiveCatalog.isDirective(parsed.name) { return nil }

        if InlineShortcutCatalog.isShortcut(parsed.name), parsed.args.isEmpty {
            if let command = registry.resolve(parsed.name) {
                guard authorization.authorize(command: command) == .allow else { return nil }
                return .command(command, parsed)
            }
        }

        guard let command = registry.resolve(parsed.name) else { return nil }
        guard command.base.category != .directive else { return nil }
        guard authorization.authorize(command: command) == .allow else { return nil }
        return .command(command, parsed)
    }

    private func containsPrivilegedTokens(in trimmed: String) -> Bool {
        guard trimmed.hasPrefix("/") else { return false }
        if DirectiveCatalog.isDirective(firstTokenName(in: trimmed)) { return true }
        if let parsed = parser.parse(trimmed) {
            if DirectiveCatalog.isDirective(parsed.name) { return true }
            if InlineShortcutCatalog.isShortcut(parsed.name) { return true }
            if registry.resolve(parsed.name) != nil { return true }
        }
        if parser.parseInput(trimmed) != nil { return true }
        return false
    }

    private func firstTokenName(in trimmed: String) -> String {
        guard trimmed.hasPrefix("/") else { return "" }
        let body = trimmed.dropFirst()
        let splitIndex = body.firstIndex(where: { $0.isWhitespace || $0 == ":" }) ?? body.endIndex
        return String(body[..<splitIndex]).lowercased()
    }

    private func containsOwnerOnlyDirective(in trimmed: String) -> Bool {
        guard trimmed.hasPrefix("/") else { return false }
        var remaining = trimmed
        while let next = remaining.firstNonWhitespacePrefix, next.hasPrefix("/") {
            guard let parsed = DirectiveCatalog.parseToken(from: remaining.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                break
            }
            if parsed.directive.kind == .model {
                return true
            }
            remaining = String(remaining.dropFirst(parsed.consumed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parsed = parser.parse(trimmed), parsed.name == "model" {
            return true
        }
        return false
    }
}

private extension String {
    var firstNonWhitespacePrefix: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
