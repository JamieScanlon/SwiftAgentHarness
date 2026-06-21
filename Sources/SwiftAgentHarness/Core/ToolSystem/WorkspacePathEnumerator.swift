import Foundation

enum WorkspacePathEnumerator {
    static func sortedRegularFileRelativePaths(
        under searchRoot: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let normalizedRoot = (searchRoot as NSString).standardizingPath
        guard let enumerator = fileManager.enumerator(atPath: normalizedRoot) else {
            return []
        }
        var paths: [String] = []
        while let next = enumerator.nextObject() as? String {
            if next.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let full = (normalizedRoot as NSString).appendingPathComponent(next)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            paths.append(normalizeRelativePath(next))
        }
        return paths.sorted()
    }

    static func normalizeRelativePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }
}
