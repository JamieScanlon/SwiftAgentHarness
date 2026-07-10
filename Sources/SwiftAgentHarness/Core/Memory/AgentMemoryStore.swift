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
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory, fileManager: .default) {
            try writeTopicAssumingLocked(filename: filename, content: content)
        }
    }

    /// Caller must already hold `MemoryFileLock.withLock` for this memory directory.
    func writeTopicAssumingLocked(filename: String, content: String) throws {
        try MemoryContentScanner.validateWrite(content).get()
        try ensureLayout()
        let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
            raw: filename,
            memoryDirectory: memoryDirectory,
            requireExists: false
        )
        try MemoryFileLock.atomicWrite(text: content, to: URL(fileURLWithPath: path), fileManager: .default)
    }

    func writeIndex(content: String) throws -> String? {
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory, fileManager: .default) {
            try writeIndexAssumingLocked(content: content)
        }
    }

    /// Caller must already hold `MemoryFileLock.withLock` for this memory directory.
    func writeIndexAssumingLocked(content: String) throws -> String? {
        let prepared = try Self.validatedTruncatedIndexContent(content)
        try ensureLayout()
        try MemoryFileLock.atomicWrite(text: prepared.text, to: indexURL, fileManager: .default)
        return prepared.capFired
    }

    func manifest() -> [MemoryManifestEntry] {
        MemoryManifestScanner.scanDirectory(memoryDirectory, fileManager: .default)
    }

    func listTopicFilenames() -> [String] {
        manifest().map(\.filename)
    }

    // MARK: - Daily staging notes (`YYYY-MM-DD.md`)

    static func isDailyFilename(_ filename: String) -> Bool {
        filename.wholeMatch(of: /^(\d{4})-(\d{2})-(\d{2})\.md$/) != nil
    }

    static func dailyFilename(
        for date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        DreamRecallStore.dayString(from: date, calendar: calendar) + ".md"
    }

    func dailyURL(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> URL {
        memoryDirectory.appendingPathComponent(Self.dailyFilename(for: date, calendar: calendar))
    }

    func readDailyBody(date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) throws -> String? {
        try readDailyBody(filename: Self.dailyFilename(for: date, calendar: calendar))
    }

    func readDailyBody(filename: String) throws -> String? {
        guard Self.isDailyFilename(filename) else { return nil }
        let url = memoryDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Appends a timestamped note to the daily staging file (no taxonomy frontmatter).
    func appendDailyNote(
        _ text: String,
        date: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date()
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try MemoryContentScanner.validateWrite(trimmed).get()
        try ensureLayout()
        let filename = Self.dailyFilename(for: date, calendar: calendar)
        let url = memoryDirectory.appendingPathComponent(filename)
        let stamp = ISO8601DateFormatter().string(from: now)
        let block = "\n## \(stamp)\n\n\(trimmed)\n"
        try MemoryFileLock.withLock(memoryDirectory: memoryDirectory, fileManager: .default) {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try MemoryFileLock.atomicWrite(text: existing + block, to: url)
            } else {
                let header = "# Daily notes \(Self.dailyFilename(for: date, calendar: calendar).replacingOccurrences(of: ".md", with: ""))\n"
                try MemoryFileLock.atomicWrite(text: header + block, to: url)
            }
        }
    }
}
