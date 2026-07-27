import Foundation

public struct AutocompleteSuggestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?
    /// Text substituted for the token being completed. Defaults to `label`.
    public var insertion: String?

    public init(id: String, label: String, detail: String? = nil, insertion: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.insertion = insertion
    }

    public var insertionText: String { insertion ?? label }
}

/// What a popup is completing. Acceptance differs by kind, so the popup has to say.
public enum AutocompleteKind: String, Sendable, Equatable {
    case slashCommand
    case filePath
}

/// Enumerates workspace files for `@`-triggered completion.
///
/// Confined to `root` by default: a completer that will happily walk to `/etc` turns a
/// convenience feature into a way to attach arbitrary host files to a turn.
public struct FilePathCompleter: Sendable {
    public var root: URL
    public var maximumResults: Int
    public var includeHidden: Bool
    public var confinesToRoot: Bool

    public init(
        root: URL,
        maximumResults: Int = 20,
        includeHidden: Bool = false,
        confinesToRoot: Bool = true
    ) {
        // Symlinks must be resolved, not just standardized: `standardizedFileURL` only
        // collapses `..` lexically, so `root/link -> /etc` would pass a prefix check and
        // the completer would happily enumerate /etc — exactly the escape this confinement
        // exists to prevent.
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumResults = max(1, maximumResults)
        self.includeHidden = includeHidden
        self.confinesToRoot = confinesToRoot
    }

    /// - Parameter token: the text after `@`, e.g. `Sources/Sur`.
    public func suggestions(for token: String) -> [AutocompleteSuggestion] {
        let (directoryPart, namePrefix) = Self.split(token)
        guard let directory = resolve(directoryPart) else { return [] }

        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }

        let lowered = namePrefix.lowercased()
        return entries
            .filter { lowered.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(lowered) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maximumResults)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                // Built from the token the user typed rather than by subtracting paths.
                // Path arithmetic here has to reconcile two spellings of the same file
                // (`/var` vs `/private/var`, symlink vs target) and gets one of them wrong
                // whichever way it leans: comparing raw paths breaks root-relative output,
                // and resolving the entry leaks a symlink's target out of the workspace.
                // The token's own directory part has neither problem, and echoes back the
                // spelling the user is already looking at.
                let relative = directoryPart.isEmpty
                    ? url.lastPathComponent
                    : directoryPart + "/" + url.lastPathComponent
                // Directories keep the trailing slash so the next keystroke descends
                // instead of restarting the completion.
                let insertion = "@" + relative + (isDirectory ? "/" : "")
                return AutocompleteSuggestion(
                    id: relative,
                    label: url.lastPathComponent + (isDirectory ? "/" : ""),
                    detail: relative,
                    insertion: insertion
                )
            }
    }

    /// Splits `Sources/Sur` into (`Sources`, `Sur`).
    static func split(_ token: String) -> (directory: String, namePrefix: String) {
        guard let slash = token.lastIndex(of: "/") else { return ("", token) }
        return (String(token[token.startIndex..<slash]), String(token[token.index(after: slash)...]))
    }

    private func resolve(_ directoryPart: String) -> URL? {
        let candidate: URL
        if directoryPart.isEmpty {
            candidate = root
        } else if directoryPart.hasPrefix("/") {
            candidate = URL(fileURLWithPath: directoryPart).standardizedFileURL
        } else if directoryPart.hasPrefix("~") {
            candidate = URL(fileURLWithPath: NSString(string: directoryPart).expandingTildeInPath).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(directoryPart).standardizedFileURL
        }

        guard confinesToRoot else { return candidate }
        // Resolve before comparing so a symlink out of the tree cannot pass the check, and
        // so both sides use the same spelling of paths like /var vs /private/var.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }

}

public struct AutocompletePopupComponent: TUIComponent {
    public var suggestions: [AutocompleteSuggestion]
    public var selectedIndex: Int
    public var kind: AutocompleteKind

    public static let visibleRowLimit = 8

    public init(
        suggestions: [AutocompleteSuggestion] = [],
        selectedIndex: Int = 0,
        kind: AutocompleteKind = .slashCommand
    ) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        self.kind = kind
    }

    public static func slashSuggestions(registry: SlashCommandRegistry, prefix: String) -> [AutocompleteSuggestion] {
        let query = prefix.hasPrefix("/") ? String(prefix.dropFirst()).lowercased() : prefix.lowercased()
        return registry.autocompleteEntries().compactMap { row in
            let name = row.name.hasPrefix("/") ? String(row.name.dropFirst()) : row.name
            guard query.isEmpty || name.lowercased().hasPrefix(query) else { return nil }
            return AutocompleteSuggestion(
                id: name,
                label: row.name,
                detail: row.description,
                insertion: row.name + " "
            )
        }
    }

    public static func fileSuggestions(completer: FilePathCompleter, token: String) -> [AutocompleteSuggestion] {
        completer.suggestions(for: token)
    }

    public func render(width: Int) -> [String] {
        guard !suggestions.isEmpty, width > 0 else { return [] }
        var lines: [String] = []
        let heading = kind == .filePath ? "Files" : "Suggestions"
        lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(ANSIStyle.dim(heading), toWidth: width)))

        // Scroll the window so the selection stays visible in long result sets.
        let limit = Self.visibleRowLimit
        let start = max(0, min(selectedIndex - limit + 1, suggestions.count - limit))
        let window = suggestions.dropFirst(max(0, start)).prefix(limit)

        for (offset, suggestion) in window.enumerated() {
            let index = max(0, start) + offset
            let marker = index == selectedIndex ? "▸" : " "
            var line = "\(marker) \(suggestion.label)"
            if let detail = suggestion.detail, detail != suggestion.label {
                line += ANSIStyle.dim(" — \(detail)")
            }
            lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width)))
        }
        return lines
    }

    public func invalidate() {}
}
