import Foundation

enum ExecutablePathResolver {
    static let defaultPath = "/usr/bin:/bin"

    static func resolve(
        _ executable: String,
        path: String?,
        cwd: String?,
        fileManager: FileManager = .default
    ) -> String? {
        if executable.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }
        if executable.contains("/") {
            let base = cwd ?? fileManager.currentDirectoryPath
            let resolved = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(executable)
                .standardizedFileURL
                .path
            return fileManager.isExecutableFile(atPath: resolved) ? resolved : nil
        }
        let pathEnv = path ?? defaultPath
        for directory in pathEnv.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
