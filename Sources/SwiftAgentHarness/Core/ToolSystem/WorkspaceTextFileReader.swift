import Foundation

enum WorkspaceTextFileReader {
    static let maxFileBytes = 1_048_576
    static let binaryProbeBytes = 8_192

    static func isTextReadableFile(at path: String, fileManager: FileManager = .default) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        guard size.intValue <= maxFileBytes else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let probe = handle.readData(ofLength: binaryProbeBytes)
        if probe.contains(0) { return false }
        return String(data: probe, encoding: .utf8) != nil
    }

    static func readUTF8(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
              data.count <= maxFileBytes else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
