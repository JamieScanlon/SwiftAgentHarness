import Darwin
import Foundation

public enum FilesystemCanonicalPath {
    public static func resolve(_ path: String, fileManager: FileManager = .default) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if path.withCString({ realpath($0, &buffer) }) != nil {
            return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        let lastComponent = (standardized as NSString).lastPathComponent
        guard parent != standardized,
              !parent.isEmpty,
              fileManager.fileExists(atPath: parent) else {
            return standardized
        }
        let canonicalParent = resolve(parent, fileManager: fileManager)
        guard !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else {
            return canonicalParent
        }
        return (canonicalParent as NSString).appendingPathComponent(lastComponent)
    }
}
