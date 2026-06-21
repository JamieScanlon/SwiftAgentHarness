import Foundation

actor SubdirectoryHintTracker {
    private var visitedDirectories = Set<String>()

    func appendHintsIfNeeded(
        toolName: String,
        toolArgumentsJSON: String?,
        toolResultContent: String,
        fileManager: FileManager = .default
    ) -> String {
        guard isPathObservingTool(toolName) else { return toolResultContent }
        let paths = extractPaths(from: toolArgumentsJSON)
        guard !paths.isEmpty else {
            return toolResultContent
        }
        var hints: [String] = []
        for path in paths {
            let directory = pathIsDirectory(path, fileManager: fileManager)
                ? path
                : (path as NSString).deletingLastPathComponent
            let normalized = (directory as NSString).standardizingPath
            guard !normalized.isEmpty, normalized != "/" else { continue }
            guard !visitedDirectories.contains(normalized) else { continue }
            visitedDirectories.insert(normalized)
            let discovered = ProjectInstructionDiscovery.discoverInDirectory(normalized, fileManager: fileManager)
            for filePath in discovered {
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
                let scan = ProjectInstructionContentScanner.scan(content)
                guard scan.isClean else { continue }
                let truncated = ProjectInstructionLoader.truncateIfNeeded(content, path: filePath)
                hints.append("""
[Subdirectory instruction hint from \(filePath)]
\(truncated)
""")
            }
        }
        guard !hints.isEmpty else { return toolResultContent }
        return toolResultContent + "\n\n" + hints.joined(separator: "\n\n")
    }

    func reset() {
        visitedDirectories.removeAll()
    }

    private func isPathObservingTool(_ name: String) -> Bool {
        switch name {
        case "read_file", "write_file", "edit_file", "glob", "grep", "bash":
            return true
        default:
            return false
        }
    }

    private func pathIsDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func extractPaths(from json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var paths: [String] = []
        for key in ["file_path", "path", "directory", "target_directory", "pattern"] {
            if let value = object[key] as? String, !value.isEmpty { paths.append(value) }
        }
        if let command = object["command"] as? String {
            paths.append(contentsOf: tokenizePaths(from: command))
        }
        return paths
    }

    private func tokenizePaths(from command: String) -> [String] {
        command.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.hasPrefix("/") || $0.hasPrefix(".") || $0.contains("/") }
    }
}
