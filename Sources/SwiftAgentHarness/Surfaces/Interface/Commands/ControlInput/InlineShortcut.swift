import Foundation

public enum InlineShortcutKind: String, Sendable, Equatable, CaseIterable {
    case help
    case commands
    case status
    case whoami
}

public struct InlineShortcutInvocation: Sendable, Equatable {
    public var kind: InlineShortcutKind

    public init(kind: InlineShortcutKind) {
        self.kind = kind
    }
}

public enum InlineShortcutCatalog {
    public static let shortcutNames: Set<String> = Set(InlineShortcutKind.allCases.map(\.rawValue))

    public static func isShortcut(_ name: String) -> Bool {
        shortcutNames.contains(DirectiveCatalog.normalize(name))
    }

    public static func kind(for name: String) -> InlineShortcutKind? {
        InlineShortcutKind(rawValue: DirectiveCatalog.normalize(name))
    }

    public static func render(
        _ invocation: InlineShortcutInvocation,
        registry: SlashCommandRegistry,
        senderLabel: String? = nil
    ) -> String {
        switch invocation.kind {
        case .help:
            return renderHelp(registry: registry)
        case .commands:
            return renderCommands(registry: registry)
        case .status:
            return "Status: session active."
        case .whoami:
            if let senderLabel, !senderLabel.isEmpty {
                return "You are `\(senderLabel)`."
            }
            return "Sender identity unavailable on this surface."
        }
    }

    public static func renderHelp(registry: SlashCommandRegistry) -> String {
        let rows = registry.autocompleteEntries(includeHidden: false)
        guard !rows.isEmpty else {
            return "No slash commands registered."
        }
        let essential = rows.filter { $0.bypassTier != .queued || isEssential($0.name) }
        let lines = essential.prefix(12).map { entry in
            var line = entry.name
            if let hint = entry.argumentHint, !hint.isEmpty {
                line += " \(hint)"
            }
            line += " — \(entry.description)"
            return line
        }
        return "Available commands:\n" + lines.joined(separator: "\n")
    }

    public static func renderCommands(registry: SlashCommandRegistry) -> String {
        let rows = registry.autocompleteEntries(includeHidden: false)
        guard !rows.isEmpty else {
            return "No slash commands registered."
        }
        return rows.map(\.name).sorted().joined(separator: ", ")
    }

    private static func isEssential(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["/help", "/status", "/new", "/stop", "/compact"].contains(normalized)
    }
}
