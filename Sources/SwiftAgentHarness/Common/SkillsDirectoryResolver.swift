import Foundation

enum SkillsDirectoryResolver {
    static func resolve(workspaceRoot: String, configuredPath: String?) -> URL? {
        guard let configuredPath else { return nil }
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let root = (workspaceRoot as NSString).standardizingPath
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: true)
    }
}
