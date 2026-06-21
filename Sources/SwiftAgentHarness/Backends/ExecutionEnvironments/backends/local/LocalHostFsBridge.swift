import Foundation

public struct LocalHostFsBridge: SandboxFsBridge {
    private let workspaceRoot: String
    private let memoryDirectory: URL?
    private let memoryWriteOnly: Bool

    public init(
        context: SandboxFsBridgeContext,
        memoryWriteOnly: Bool = false
    ) {
        self.workspaceRoot = FilesystemCanonicalPath.resolve(context.workspaceRoot)
        self.memoryDirectory = context.memoryDirectory.map { URL(fileURLWithPath: $0) }
        self.memoryWriteOnly = memoryWriteOnly
    }

    public func stat(path: String) async throws -> SandboxFsStat {
        let resolved = try resolveReadPath(raw: path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
        let size = (try? FileManager.default.attributesOfItem(atPath: resolved)[.size] as? NSNumber)?.int64Value ?? 0
        return SandboxFsStat(isDirectory: isDir.boolValue, size: size, exists: exists)
    }

    public func readFile(path: String) async throws -> Data {
        let resolved = try resolveReadPath(raw: path)
        return try Data(contentsOf: URL(fileURLWithPath: resolved))
    }

    public func writeFile(path: String, content: Data) async throws {
        let resolved = try resolveWritePath(raw: path, requireExists: false)
        try QueuedFileWriter.write(data: content, to: resolved)
    }

    public func mkdir(path: String) async throws {
        let resolved = try resolveWritePath(raw: path, requireExists: false)
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
    }

    public func rename(from: String, to: String) async throws {
        let src = try resolveWritePath(raw: from, requireExists: true)
        let dst = try resolveWritePath(raw: to, requireExists: false)
        try FileManager.default.moveItem(atPath: src, toPath: dst)
    }

    public func remove(path: String) async throws {
        let resolved = try resolveWritePath(raw: path, requireExists: true)
        try FileManager.default.removeItem(atPath: resolved)
    }

    private func resolveReadPath(raw: String) throws -> String {
        if memoryWriteOnly, let memoryDirectory {
            return try PathPolicy.resolveMemoryRelativePath(
                raw: raw,
                memoryDirectory: memoryDirectory,
                requireExists: true
            )
        }
        return try PathPolicy.resolveReadablePath(
            raw: raw,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectory,
            memoryWriteOnly: false
        )
    }

    private func resolveWritePath(raw: String, requireExists: Bool) throws -> String {
        if memoryWriteOnly, let memoryDirectory {
            return try PathPolicy.resolveMemoryRelativePath(
                raw: raw,
                memoryDirectory: memoryDirectory,
                requireExists: requireExists
            )
        }
        return try PathPolicy.resolveWritablePath(
            raw: raw,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectory,
            memoryWriteOnly: false
        )
    }
}
