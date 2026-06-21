import Foundation

enum TeamMemoryPathValidator {
    enum ValidationError: Error, Equatable {
        case nullByte
        case traversal
        case absolutePath
        case outsideTeamDirectory
        case symlinkLoop
        case unverifiable
    }

    static func validateWritePath(
        teamDirectory: URL,
        relativeKey: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        if relativeKey.contains("\0") { throw ValidationError.nullByte }
        if relativeKey.contains("..") || relativeKey.contains("%2e") { throw ValidationError.traversal }
        if relativeKey.hasPrefix("/") || relativeKey.hasPrefix("\\") { throw ValidationError.absolutePath }
        let joined = teamDirectory.appendingPathComponent(relativeKey).standardizedFileURL
        let teamRoot = teamDirectory.standardizedFileURL.path
        let joinedPath = joined.path
        guard joinedPath == teamRoot || joinedPath.hasPrefix(teamRoot + "/") else {
            throw ValidationError.outsideTeamDirectory
        }
        return try verifyRealPathContainment(target: joined, root: teamDirectory, fileManager: fileManager)
    }

    private static func verifyRealPathContainment(
        target: URL,
        root: URL,
        fileManager: FileManager
    ) throws -> URL {
        var existing = target
        var tailComponents: [String] = []
        while !fileManager.fileExists(atPath: existing.path) {
            tailComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
            if existing.path == "/" || existing.path.isEmpty { break }
        }
        var resolved = URL(fileURLWithPath: existing.path, isDirectory: true).resolvingSymlinksInPath().path
        if resolved.isEmpty { throw ValidationError.unverifiable }
        for component in tailComponents {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        let rootReal = URL(fileURLWithPath: root.path, isDirectory: true).resolvingSymlinksInPath().path
        guard resolved == rootReal || resolved.hasPrefix(rootReal + "/") else {
            throw ValidationError.outsideTeamDirectory
        }
        return URL(fileURLWithPath: resolved)
    }
}
