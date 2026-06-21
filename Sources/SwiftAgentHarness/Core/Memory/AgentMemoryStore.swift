import Foundation

struct AgentMemoryStore: Sendable {
    let memoryDirectory: URL

    init(memoryDirectory: URL, fileManager: FileManager = .default) {
        self.memoryDirectory = memoryDirectory
        _ = fileManager
    }

    var indexURL: URL { memoryDirectory.appendingPathComponent("MEMORY.md") }
    var teamDirectory: URL { memoryDirectory.appendingPathComponent("team", isDirectory: true) }

    func ensureLayout() throws {
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try MemoryFileLock.atomicWrite(text: "", to: indexURL, fileManager: .default)
        }
    }

    static func validatedTruncatedIndexContent(_ content: String) throws -> (text: String, capFired: String?) {
        try MemoryContentScanner.validateWrite(content).get()
        let truncated = MemoryIndexTruncator.truncate(content)
        return (truncated.text, truncated.capFired)
    }

    func readIndexSnapshot() throws -> String {
        try ensureLayout()
        let raw = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        return MemoryIndexTruncator.truncate(raw).text
    }

    func readTopicBody(filename: String) throws -> String? {
        let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
            raw: filename,
            memoryDirectory: memoryDirectory,
            requireExists: true
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func writeTopic(filename: String, content: String) throws {
        try MemoryContentScanner.validateWrite(content).get()
        try ensureLayout()
        let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
            raw: filename,
            memoryDirectory: memoryDirectory,
            requireExists: false
        )
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory, fileManager: .default) {
            try MemoryFileLock.atomicWrite(text: content, to: URL(fileURLWithPath: path), fileManager: .default)
        }
    }

    func writeIndex(content: String) throws -> String? {
        let prepared = try Self.validatedTruncatedIndexContent(content)
        try ensureLayout()
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory, fileManager: .default) {
            try MemoryFileLock.atomicWrite(text: prepared.text, to: indexURL, fileManager: .default)
        }
        return prepared.capFired
    }

    func manifest() -> [MemoryManifestEntry] {
        MemoryManifestScanner.scanDirectory(memoryDirectory, fileManager: .default)
    }

    func listTopicFilenames() -> [String] {
        manifest().map(\.filename)
    }
}
