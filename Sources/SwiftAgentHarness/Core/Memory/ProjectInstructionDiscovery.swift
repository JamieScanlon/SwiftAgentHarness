import Foundation

struct ProjectInstructionFile: Sendable, Equatable {
    let path: String
    let layer: ProjectInstructionLayer
    let isLocal: Bool
}

enum ProjectInstructionLayer: String, Sendable, Equatable, Comparable {
    case managed
    case user
    case project
    case local

    static func < (lhs: ProjectInstructionLayer, rhs: ProjectInstructionLayer) -> Bool {
        let order: [ProjectInstructionLayer] = [.managed, .user, .project, .local]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

enum ProjectInstructionDiscovery {
    static let instructionFramingHeader =
        "*Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.*"

    static func discoverFiles(
        cwd: String,
        canonicalGitRoot: String?,
        managedPath: String?,
        userConfigDir: URL,
        fileManager: FileManager = .default
    ) -> [ProjectInstructionFile] {
        var files: [ProjectInstructionFile] = []
        if let managedPath, fileManager.fileExists(atPath: managedPath) {
            files.append(ProjectInstructionFile(path: managedPath, layer: .managed, isLocal: false))
        }
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let userPath = userConfigDir.appendingPathComponent(name).path
            if fileManager.fileExists(atPath: userPath) {
                files.append(ProjectInstructionFile(path: userPath, layer: .user, isLocal: false))
            }
        }
        files.append(contentsOf: walkProjectLayers(
            cwd: cwd,
            canonicalGitRoot: canonicalGitRoot,
            fileManager: fileManager
        ))
        return files.sorted { lhs, rhs in
            if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
            return lhs.path < rhs.path
        }
    }

    /// Nearest primary instruction file walking upward from `cwd`. Prefers `AGENTS.md` over `CLAUDE.md`
    /// at the same directory level.
    static func nearestPrimaryInstructionFile(
        cwd: String,
        fileManager: FileManager = .default
    ) -> String? {
        var current = (cwd as NSString).standardizingPath
        let root = "/"
        while true {
            if let path = primaryInstructionFileInDirectory(current, fileManager: fileManager) {
                return path
            }
            if current == root { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func primaryInstructionFileInDirectory(
        _ directory: String,
        fileManager: FileManager
    ) -> String? {
        let agents = (directory as NSString).appendingPathComponent("AGENTS.md")
        if fileManager.fileExists(atPath: agents) { return agents }
        let claude = (directory as NSString).appendingPathComponent("CLAUDE.md")
        if fileManager.fileExists(atPath: claude) { return claude }
        let claudeAlt = (directory as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fileManager.fileExists(atPath: claudeAlt) { return claudeAlt }
        return nil
    }

    static func discoverInDirectory(_ directory: String, fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        let names = ["AGENTS.md", "CLAUDE.md", "AGENTS.local.md", "CLAUDE.local.md", ".cursorrules"]
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) { found.append(path) }
        }
        let claudeAlt = (directory as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fileManager.fileExists(atPath: claudeAlt) { found.append(claudeAlt) }
        let rulesDir = (directory as NSString).appendingPathComponent(".claude/rules")
        if let rules = try? fileManager.contentsOfDirectory(atPath: rulesDir) {
            for rule in rules where rule.hasSuffix(".md") {
                found.append((rulesDir as NSString).appendingPathComponent(rule))
            }
        }
        return found.sorted()
    }

    private static func walkProjectLayers(
        cwd: String,
        canonicalGitRoot: String?,
        fileManager: FileManager
    ) -> [ProjectInstructionFile] {
        var files: [ProjectInstructionFile] = []
        var current = (cwd as NSString).standardizingPath
        let root = "/"
        while true {
            files.append(contentsOf: collectAtLevel(
                directory: current,
                canonicalGitRoot: canonicalGitRoot,
                fileManager: fileManager
            ))
            if current == root { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return files
    }

    private static func collectAtLevel(
        directory: String,
        canonicalGitRoot: String?,
        fileManager: FileManager
    ) -> [ProjectInstructionFile] {
        var files: [ProjectInstructionFile] = []
        let insideGitRoot = canonicalGitRoot.map { GitRootResolver.isInsideCanonicalGitRoot(path: directory, canonicalRoot: $0) } ?? false
        _ = insideGitRoot

        for name in ["AGENTS.md", "CLAUDE.md"] {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) {
                files.append(ProjectInstructionFile(path: path, layer: .project, isLocal: false))
            }
        }
        let claudeAlt = (directory as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fileManager.fileExists(atPath: claudeAlt) {
            files.append(ProjectInstructionFile(path: claudeAlt, layer: .project, isLocal: false))
        }
        let rulesDir = (directory as NSString).appendingPathComponent(".claude/rules")
        if let rules = try? fileManager.contentsOfDirectory(atPath: rulesDir) {
            for rule in rules where rule.hasSuffix(".md") {
                let path = (rulesDir as NSString).appendingPathComponent(rule)
                files.append(ProjectInstructionFile(path: path, layer: .project, isLocal: false))
            }
        }
        for name in ["AGENTS.local.md", "CLAUDE.local.md"] {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) {
                files.append(ProjectInstructionFile(path: path, layer: .local, isLocal: true))
            }
        }
        return files
    }
}
