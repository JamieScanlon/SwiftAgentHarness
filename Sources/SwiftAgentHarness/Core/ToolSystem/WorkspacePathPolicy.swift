import Foundation

enum WorkspacePathPolicy {
    static func isPathInsideRoot(_ path: String, root: String) -> Bool {
        PathPolicy.isPathInsideRoot(path, root: root)
    }

    static func isPathInsideAnyRoot(_ path: String, roots: [String]) -> Bool {
        PathPolicy.isPathInsideAnyRoot(path, roots: roots)
    }

    static func resolveMemoryRelativePath(
        raw: String,
        memoryDirectory: URL,
        requireExists: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        try PathPolicy.resolveMemoryRelativePath(raw: raw, memoryDirectory: memoryDirectory, requireExists: requireExists, fileManager: fileManager)
    }

    static func resolveReadablePath(
        raw: String,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        try PathPolicy.resolveReadablePath(raw: raw, workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly, fileManager: fileManager)
    }

    static func resolveWritablePath(
        raw: String,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        try PathPolicy.resolveWritablePath(raw: raw, workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly, fileManager: fileManager)
    }

    static func resolveSearchRoot(
        raw: String?,
        workspaceRoot: String,
        memoryDirectory: URL?,
        memoryWriteOnly: Bool,
        fileManager: FileManager = .default
    ) throws -> String {
        try PathPolicy.resolveSearchRoot(raw: raw, workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, memoryWriteOnly: memoryWriteOnly, fileManager: fileManager)
    }

    static func resolveExistingPathForTesting(
        _ path: String,
        maxSymlinkDepth: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        try PathPolicy.resolveExistingPathForTesting(path, maxSymlinkDepth: maxSymlinkDepth, fileManager: fileManager)
    }
}
