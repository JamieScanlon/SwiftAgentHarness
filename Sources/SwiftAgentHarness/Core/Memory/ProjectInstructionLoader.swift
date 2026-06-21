import Foundation

enum ProjectInstructionLoader {
    static let maxFileBytes = 40_960
    private static let headFraction = 0.7

    struct LoadedInstructions: Sendable {
        let text: String
        let loadedPaths: [String]
        let blockedPaths: [(path: String, threats: [String])]
    }

    static func load(
        cwd: String,
        canonicalGitRoot: String?,
        managedPath: String?,
        userConfigDir: URL,
        fileManager: FileManager = .default
    ) -> LoadedInstructions {
        let discovered = ProjectInstructionDiscovery.discoverFiles(
            cwd: cwd,
            canonicalGitRoot: canonicalGitRoot,
            managedPath: managedPath,
            userConfigDir: userConfigDir,
            fileManager: fileManager
        )
        let projectAndLocal = discovered.filter { $0.layer == .project || $0.layer == .local }
        let outer = discovered.filter { $0.layer == .managed || $0.layer == .user }
        let reversedProject = projectAndLocal.reversed()
        let ordered = outer + reversedProject

        var parts: [String] = [ProjectInstructionDiscovery.instructionFramingHeader]
        var loadedPaths: [String] = []
        var blocked: [(path: String, threats: [String])] = []

        for file in ordered {
            guard let raw = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            let scan = ProjectInstructionContentScanner.scan(raw)
            if !scan.isClean {
                blocked.append((file.path, scan.matchedThreatIDs))
                continue
            }
            let truncated = truncateIfNeeded(raw, path: file.path)
            parts.append("<!-- \(file.path) -->\n\(truncated)")
            loadedPaths.append(file.path)
        }
        let text = parts.count > 1 ? parts.joined(separator: "\n\n") : ""
        return LoadedInstructions(text: text, loadedPaths: loadedPaths, blockedPaths: blocked)
    }

    static func truncateIfNeeded(_ content: String, path: String) -> String {
        let data = Data(content.utf8)
        guard data.count > maxFileBytes else { return content }
        let headBytes = Int(Double(maxFileBytes) * headFraction)
        let tailBytes = maxFileBytes - headBytes - 80
        let head = String(decoding: data.prefix(headBytes), as: UTF8.self)
        let tail = String(decoding: data.suffix(max(0, tailBytes)), as: UTF8.self)
        return """
\(head)

[... truncated \(path): \(data.count) bytes total; use file tools to read the remainder ...]

\(tail)
"""
    }
}
