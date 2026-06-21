import Foundation

enum MemoryConfigHome {
    static func resolve(fileManager: FileManager = .default) -> URL {
        HarnessHostPaths.applicationSupportDirectory(fileManager: fileManager)
    }

    static func userSettingsURL(fileManager: FileManager = .default) -> URL {
        HarnessHostPaths.userSettingsURL(fileManager: fileManager)
    }
}

enum AgentMemoryPathResolver {
    static let overrideEnvKey = "SAH_MEMORY_PATH_OVERRIDE"

    static func resolveMemoryDirectory(
        canonicalGitRoot: String?,
        cwd: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override = ProcessInfo.processInfo.environment[overrideEnvKey],
           !override.isEmpty {
            return try validateAbsoluteDirectory((override as NSString).expandingTildeInPath, fileManager: fileManager)
        }
        if let fromSettings = readTrustedAutoMemoryDirectory(fileManager: fileManager) {
            return try validateAbsoluteDirectory(fromSettings, fileManager: fileManager)
        }
        let key = sanitizedProjectKey(canonicalGitRoot: canonicalGitRoot, cwd: cwd)
        let dir = MemoryConfigHome.resolve(fileManager: fileManager)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sanitizedProjectKey(canonicalGitRoot: String?, cwd: String) -> String {
        let basis = canonicalGitRoot ?? cwd
        let normalized = (basis as NSString).standardizingPath
        let slug = normalized
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let hash = MemoryPathHashing.sha1Prefix(normalized)
        return "\(slug)-\(hash)"
    }

    static func validateAbsoluteDirectory(_ path: String, fileManager: FileManager) throws -> URL {
        if path.contains("\0") { throw MemoryPathValidationError.nullByte }
        if path.hasPrefix("\\\\") { throw MemoryPathValidationError.uncPath }
        if path.hasPrefix("~/.") || path.hasPrefix("~/..") { throw MemoryPathValidationError.unsafeTildeExpansion }
        if !path.hasPrefix("/") { throw MemoryPathValidationError.relativePath }
        let normalized = (path as NSString).standardizingPath
        if normalized == "/" || normalized == "/private" || normalized == "/System" {
            throw MemoryPathValidationError.rootOrNearRoot
        }
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: normalized, isDirectory: &isDir) {
            guard isDir.boolValue else { throw MemoryPathValidationError.invalidPath("not a directory") }
        } else {
            try fileManager.createDirectory(atPath: normalized, withIntermediateDirectories: true)
        }
        return URL(fileURLWithPath: normalized, isDirectory: true)
    }

    static func isPathInsideMemoryDirectory(_ path: String, memoryDirectory: URL) -> Bool {
        WorkspacePathPolicy.isPathInsideRoot(path, root: memoryDirectory.standardizedFileURL.path)
    }

    private static func readTrustedAutoMemoryDirectory(fileManager: FileManager) -> String? {
        let url = MemoryConfigHome.userSettingsURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["autoMemoryDirectory"] as? String,
              !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }
}

enum MemoryPathHashing {
    static func sha1Prefix(_ input: String) -> String {
        let hash = input.utf8.reduce(into: UInt64(5381)) { acc, byte in
            acc = ((acc << 5) &+ acc) &+ UInt64(byte)
        }
        return String(format: "%012llx", hash & 0xFFFFFFFFFFFF)
    }
}
