import Foundation

public enum WorkspaceFilesystemError: Error, Equatable {
    case notFound(String)
    case outsideAllowedRoots
    case symlinkEscape
    case symlinkLoop
    case writeDenied
    case invalidPath
    case readWindowRequired(String)
}

public enum PathPolicy {
    private static let defaultMaxSymlinkDepth = 40

    public static func toRelativeWorkspacePath(root: String, candidate: String) throws -> String {
        let normalizedRoot = FilesystemCanonicalPath.resolve(root)
        let path = normalize(raw: candidate, workspaceRoot: normalizedRoot)
        guard isPathInsideRoot(path, root: normalizedRoot) else {
            throw SandboxBackendError.pathEscapes(candidate)
        }
        return String(path.dropFirst(normalizedRoot.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public static func isPathInsideRoot(_ path: String, root: String) -> Bool {
        let normalizedPath = FilesystemCanonicalPath.resolve(path)
        let normalizedRoot = FilesystemCanonicalPath.resolve(root)
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    public static func isPathInsideAnyRoot(_ path: String, roots: [String]) -> Bool {
        roots.contains { isPathInsideRoot(path, root: $0) }
    }

    public static func resolveMemoryRelativePath(
        raw: String,
        memoryDirectory: URL,
        requireExists: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        try validateMemoryFilename(raw)
        let memoryRoot = FilesystemCanonicalPath.resolve(memoryDirectory.path)
        let path = normalize(raw: raw, workspaceRoot: memoryDirectory.path)
        guard isPathInsideRoot(path, root: memoryRoot) else {
            throw WorkspaceFilesystemError.writeDenied
        }
        try verifySymlinkContainment(path: path, allowedRoots: [memoryRoot], fileManager: fileManager)
        if requireExists {
            guard fileManager.fileExists(atPath: path) else {
                throw WorkspaceFilesystemError.notFound(path)
            }
            return try resolveExistingPath(path, fileManager: fileManager)
        }
        return path
    }

    public static func resolveReadablePath(
        raw: String,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        let path = try pass1NormalizedPath(
            raw: raw,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectory,
            memoryWriteOnly: memoryWriteOnly
        )
        try verifySymlinkContainment(
            path: path,
            allowedRoots: allowedRoots(workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly),
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: path) else {
            throw WorkspaceFilesystemError.notFound(path)
        }
        return path
    }

    public static func resolveWritablePath(
        raw: String,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        let path = try pass1NormalizedPath(
            raw: raw,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectory,
            memoryWriteOnly: memoryWriteOnly
        )
        try verifySymlinkContainment(
            path: path,
            allowedRoots: allowedRoots(workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly),
            fileManager: fileManager
        )
        return path
    }

    public static func resolveSearchRoot(
        raw: String?,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        let candidate = raw.map { normalize(raw: $0, workspaceRoot: workspaceRoot) } ?? workspaceRoot
        let roots = allowedRoots(workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly)
        guard isPathInsideAnyRoot(candidate, roots: roots) else {
            throw WorkspaceFilesystemError.outsideAllowedRoots
        }
        try verifySymlinkContainment(path: candidate, allowedRoots: roots, fileManager: fileManager)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceFilesystemError.notFound(candidate)
        }
        return candidate
    }

    public static func normalize(raw: String, workspaceRoot: String) -> String {
        if raw.hasPrefix("/") {
            return (raw as NSString).standardizingPath
        }
        return ((workspaceRoot as NSString).appendingPathComponent(raw) as NSString).standardizingPath
    }

    public static func validateBindSource(_ source: String, allowlist: [String]) throws -> String {
        let canonical = FilesystemCanonicalPath.resolve(source)
        guard isPathInsideAnyRoot(canonical, roots: allowlist) else {
            throw SandboxBackendError.pathEscapes(source)
        }
        return canonical
    }

    private static func validateMemoryFilename(_ raw: String) throws {
        guard !raw.isEmpty, !raw.contains("\0") else { throw WorkspaceFilesystemError.invalidPath }
        guard !raw.hasPrefix("/") else { throw WorkspaceFilesystemError.invalidPath }
        if raw.contains("/") || raw.contains("..") { throw WorkspaceFilesystemError.invalidPath }
    }

    private static func pass1NormalizedPath(
        raw: String,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool
    ) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0") else { throw WorkspaceFilesystemError.invalidPath }
        let canonicalWorkspace = FilesystemCanonicalPath.resolve(workspaceRoot)
        let path = normalize(raw: raw, workspaceRoot: canonicalWorkspace)
        let roots = allowedRoots(workspaceRoot: canonicalWorkspace, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly)
        guard isPathInsideAnyRoot(path, roots: roots) else {
            throw memoryWriteOnly ? WorkspaceFilesystemError.writeDenied : WorkspaceFilesystemError.outsideAllowedRoots
        }
        return path
    }

    private static func allowedRoots(workspaceRoot: String, memoryDirectory: URL?, memoryWriteOnly: Bool) -> [String] {
        if memoryWriteOnly {
            if let memoryDirectory {
                return [FilesystemCanonicalPath.resolve(memoryDirectory.path)]
            }
            return [FilesystemCanonicalPath.resolve(workspaceRoot)]
        }
        var roots = [FilesystemCanonicalPath.resolve(workspaceRoot)]
        if let memoryDirectory {
            roots.append(FilesystemCanonicalPath.resolve(memoryDirectory.path))
        }
        return roots
    }

    private static func verifySymlinkContainment(path: String, allowedRoots: [String], fileManager: FileManager) throws {
        let normalized = (path as NSString).standardizingPath
        guard !normalized.isEmpty else { throw WorkspaceFilesystemError.invalidPath }

        var ancestor = normalized
        var tailComponents: [String] = []
        while !ancestor.isEmpty && ancestor != "/" && !fileManager.fileExists(atPath: ancestor) {
            tailComponents.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }

        if ancestor.isEmpty || ancestor == "/" { return }

        let resolvedAncestor = try resolveExistingPath(ancestor, fileManager: fileManager)
        var visited: Set<String> = [resolvedAncestor]
        guard isPathInsideAnyRoot(resolvedAncestor, roots: allowedRoots) else {
            throw WorkspaceFilesystemError.symlinkEscape
        }

        var walk = resolvedAncestor
        for component in tailComponents {
            walk = ((walk as NSString).appendingPathComponent(component) as NSString).standardizingPath
            guard isPathInsideAnyRoot(walk, roots: allowedRoots) else {
                throw WorkspaceFilesystemError.outsideAllowedRoots
            }
            guard fileManager.fileExists(atPath: walk) else { continue }
            let resolved = try resolveExistingPath(walk, fileManager: fileManager)
            guard !visited.contains(resolved) else { throw WorkspaceFilesystemError.symlinkLoop }
            visited.insert(resolved)
            guard isPathInsideAnyRoot(resolved, roots: allowedRoots) else {
                throw WorkspaceFilesystemError.symlinkEscape
            }
        }

        if fileManager.fileExists(atPath: normalized) {
            let fullyResolved = try resolveExistingPath(normalized, fileManager: fileManager)
            guard isPathInsideAnyRoot(fullyResolved, roots: allowedRoots) else {
                throw WorkspaceFilesystemError.symlinkEscape
            }
        }
    }

    private static func isSymbolicLink(at path: String, fileManager: FileManager) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    public static func resolveExistingPathForTesting(
        _ path: String,
        maxSymlinkDepth: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        try resolveExistingPath(path, maxSymlinkDepth: maxSymlinkDepth, fileManager: fileManager)
    }

    private static func resolveExistingPath(
        _ path: String,
        maxSymlinkDepth: Int? = nil,
        fileManager: FileManager
    ) throws -> String {
        let depthLimit = maxSymlinkDepth ?? defaultMaxSymlinkDepth
        guard fileManager.fileExists(atPath: path) else { throw WorkspaceFilesystemError.notFound(path) }
        var current = (path as NSString).standardizingPath
        var depth = 0
        while isSymbolicLink(at: current, fileManager: fileManager) {
            guard depth < depthLimit else { throw WorkspaceFilesystemError.symlinkLoop }
            let destination = try fileManager.destinationOfSymbolicLink(atPath: current)
            if destination.hasPrefix("/") {
                current = (destination as NSString).standardizingPath
            } else {
                let base = (current as NSString).deletingLastPathComponent
                current = ((base as NSString).appendingPathComponent(destination) as NSString).standardizingPath
            }
            guard fileManager.fileExists(atPath: current) else { throw WorkspaceFilesystemError.symlinkEscape }
            depth += 1
        }
        return current
    }
}
