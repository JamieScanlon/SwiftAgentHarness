import Foundation

enum GitRootResolver {
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String?] = [:]

    static func canonicalGitRoot(for cwd: String, fileManager: FileManager = .default) -> String? {
        let normalized = (cwd as NSString).standardizingPath
        cacheLock.lock()
        if let cached = cache[normalized] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = resolveGitRoot(for: normalized, fileManager: fileManager)
        cacheLock.lock()
        cache[normalized] = resolved
        cacheLock.unlock()
        return resolved
    }

    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private static func resolveGitRoot(for cwd: String, fileManager: FileManager) -> String? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty else { return nil }
            return (output as NSString).standardizingPath
        } catch {
            return nil
        }
    }

    static func isInsideCanonicalGitRoot(path: String, canonicalRoot: String) -> Bool {
        let normalizedPath = (path as NSString).standardizingPath
        let normalizedRoot = (canonicalRoot as NSString).standardizingPath
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }
}
