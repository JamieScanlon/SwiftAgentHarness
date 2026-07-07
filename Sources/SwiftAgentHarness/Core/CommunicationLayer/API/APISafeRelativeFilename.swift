import Foundation

enum APISafeRelativeFilename {
    /// Returns nil when the name is unsafe for use as a single path component under a trusted root.
    static func validate(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        guard raw.count <= 256 else { return nil }
        guard !raw.contains("/"), !raw.contains("\\"), !raw.contains("..") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// Resolves `relativeName` under `root` when it passes validation and remains contained after standardization.
    static func resolveContainedFileURL(
        root: URL,
        relativeName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let safeName = validate(relativeName) else { return nil }
        let tempRoot = root.standardizedFileURL
        let candidate = tempRoot.appendingPathComponent(safeName).standardizedFileURL
        let rootPath = tempRoot.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return verifyRealPathContainment(target: candidate, root: tempRoot, fileManager: fileManager)
    }

    private static func verifyRealPathContainment(
        target: URL,
        root: URL,
        fileManager: FileManager
    ) -> URL? {
        var existing = target
        var tailComponents: [String] = []
        while !fileManager.fileExists(atPath: existing.path) {
            tailComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
            if existing.path == "/" || existing.path.isEmpty { break }
        }
        var resolved = URL(fileURLWithPath: existing.path, isDirectory: true).resolvingSymlinksInPath().path
        if resolved.isEmpty { return nil }
        for component in tailComponents {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        let rootReal = URL(fileURLWithPath: root.path, isDirectory: true).resolvingSymlinksInPath().path
        guard resolved == rootReal || resolved.hasPrefix(rootReal + "/") else { return nil }
        return URL(fileURLWithPath: resolved)
    }
}
