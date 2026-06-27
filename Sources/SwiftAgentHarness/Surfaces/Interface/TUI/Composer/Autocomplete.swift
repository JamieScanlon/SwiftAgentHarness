import Foundation

public struct AutocompleteSuggestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public enum AutocompleteSource: Sendable {
    case slashCommands(SlashCommandRegistry)
    case filePaths([String])
}

public struct AutocompletePopupComponent: TUIComponent {
    public var suggestions: [AutocompleteSuggestion]
    public var selectedIndex: Int

    public init(suggestions: [AutocompleteSuggestion] = [], selectedIndex: Int = 0) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
    }

    public static func slashSuggestions(registry: SlashCommandRegistry, prefix: String) -> [AutocompleteSuggestion] {
        let query = prefix.hasPrefix("/") ? String(prefix.dropFirst()).lowercased() : prefix.lowercased()
        return registry.autocompleteEntries().compactMap { row in
            let name = row.name.hasPrefix("/") ? String(row.name.dropFirst()) : row.name
            guard query.isEmpty || name.lowercased().hasPrefix(query) else { return nil }
            return AutocompleteSuggestion(id: name, label: row.name, detail: row.description)
        }
    }

    public static func fileSuggestions(paths: [String], prefix: String) -> [AutocompleteSuggestion] {
        paths.filter { $0.hasPrefix(prefix) || prefix.isEmpty }.map {
            AutocompleteSuggestion(id: $0, label: $0)
        }
    }

    public func render(width: Int) -> [String] {
        guard !suggestions.isEmpty else { return [] }
        var lines: [String] = []
        lines.append(ANSIStyle.finishLine(ANSIStyle.dim("Suggestions")))
        for (index, suggestion) in suggestions.prefix(8).enumerated() {
            let marker = index == selectedIndex ? "▸" : " "
            var line = "\(marker) \(suggestion.label)"
            if let detail = suggestion.detail {
                line += ANSIStyle.dim(" — \(detail)")
            }
            lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width)))
        }
        return lines
    }

    public func invalidate() {}
}
