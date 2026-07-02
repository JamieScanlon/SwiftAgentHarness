import Foundation

enum SandboxHostPaths {
    static func localExecTempDirectory(scopeKey: String, fileManager: FileManager = .default) -> URL {
        HarnessHostPaths.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("sandbox-tmp/local-\(scopeKey)", isDirectory: true)
    }

    static func openshellMirrorRoot(scopeKey: String, fileManager: FileManager = .default) -> URL {
        HarnessHostPaths.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("openshell-mirrors/\(scopeKey)", isDirectory: true)
    }

    static func ensureDirectory(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
