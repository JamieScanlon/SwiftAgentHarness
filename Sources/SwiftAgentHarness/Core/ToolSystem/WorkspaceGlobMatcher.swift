import Foundation

enum WorkspaceGlobMatcher {
    static func matches(relativePath: String, pattern: String) -> Bool {
        let normalizedPath = WorkspacePathEnumerator.normalizeRelativePath(relativePath)
        let normalizedPattern = WorkspacePathEnumerator.normalizeRelativePath(
            pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedPattern.isEmpty else { return false }
        if normalizedPattern == "*" { return true }
        guard let regex = try? regex(for: normalizedPattern) else { return false }
        let range = NSRange(normalizedPath.startIndex..<normalizedPath.endIndex, in: normalizedPath)
        return regex.firstMatch(in: normalizedPath, options: [], range: range) != nil
    }

    private static func regex(for pattern: String) throws -> NSRegularExpression {
        var regexBody = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            if pattern[index] == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterGlobstar = pattern.index(after: next)
                    if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
                        regexBody += "(?:.*/)?"
                        index = pattern.index(after: afterGlobstar)
                        continue
                    }
                    regexBody += ".*"
                    index = afterGlobstar
                    continue
                }
                regexBody += "[^/]*"
                index = next
                continue
            }
            if pattern[index] == "?" {
                regexBody += "."
                index = pattern.index(after: index)
                continue
            }
            regexBody += NSRegularExpression.escapedPattern(for: String(pattern[index]))
            index = pattern.index(after: index)
        }
        return try NSRegularExpression(pattern: "^\(regexBody)$", options: [])
    }
}
