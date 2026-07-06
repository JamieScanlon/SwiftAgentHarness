import Foundation

/// Resolves operator-controlled project mode-profile directories outside agent write scope.
enum ModeProfileProjectConfigDirectoryResolver {
    static let overrideEnvKey = "SAH_MODE_PROFILES_PROJECT_DIR"

    struct Resolution: Sendable {
        let directory: URL?
        let diagnostics: [String]
    }

    static func resolve(
        cwd: String,
        canonicalGitRoot: String? = nil,
        fileManager: FileManager = .default
    ) -> Resolution {
        var diagnostics: [String] = []
        let normalizedCWD = (cwd as NSString).standardizingPath
        let gitRoot = canonicalGitRoot ?? GitRootResolver.canonicalGitRoot(for: normalizedCWD, fileManager: fileManager)

        let directoryURL: URL
        if let override = HarnessEnvironmentOverride.string(overrideEnvKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            directoryURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let key = AgentMemoryPathResolver.sanitizedProjectKey(canonicalGitRoot: gitRoot, cwd: normalizedCWD)
            directoryURL = HarnessHostPaths.applicationSupportDirectory(fileManager: fileManager)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
                .appendingPathComponent("mode-profiles", isDirectory: true)
        }

        let writeRoots = agentWriteRoots(
            cwd: normalizedCWD,
            canonicalGitRoot: gitRoot,
            fileManager: fileManager
        )
        let dirPath = directoryURL.standardizedFileURL.path
        if PathPolicy.isPathInsideAnyRoot(dirPath, roots: writeRoots) {
            diagnostics.append("project mode config directory rejected: inside agent write scope")
            return Resolution(directory: nil, diagnostics: diagnostics)
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            diagnostics.append("project mode config directory failed to create '\(directoryURL.lastPathComponent)': \(error.localizedDescription)")
            return Resolution(directory: nil, diagnostics: diagnostics)
        }

        return Resolution(directory: directoryURL, diagnostics: diagnostics)
    }

    private static func agentWriteRoots(
        cwd: String,
        canonicalGitRoot: String?,
        fileManager: FileManager
    ) -> [String] {
        var roots = [cwd]
        if let gitRoot = canonicalGitRoot {
            roots.append((gitRoot as NSString).standardizingPath)
        }
        if let memoryDirectory = try? AgentMemoryPathResolver.resolveMemoryDirectory(
            canonicalGitRoot: canonicalGitRoot,
            cwd: cwd,
            fileManager: fileManager
        ) {
            roots.append(memoryDirectory.standardizedFileURL.path)
        }
        return roots
    }
}
