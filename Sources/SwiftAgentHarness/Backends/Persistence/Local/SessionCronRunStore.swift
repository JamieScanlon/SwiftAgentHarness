//
//  Append-only JSONL for cron/task runs (`cron/runs/<jobId>.jsonl`).
//

import Foundation

enum SessionCronRunStore {
    static func append(root: URL, jobId: String, lineJSON: Data) throws {
        let url = SessionPersistenceLayout.cronRunFileURL(root: root, jobId: jobId)
        try SessionPersistenceLayout.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(lineJSON)
        handle.write(Data("\n".utf8))
        try handle.synchronize()
    }

    /// Returns the last `limit` non-empty decoded lines (most recent last).
    static func tail(root: URL, jobId: String, limit: Int) throws -> [SessionHarnessTaskRunRecord] {
        guard limit > 0 else { return [] }
        let url = SessionPersistenceLayout.cronRunFileURL(root: root, jobId: jobId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let trimmed = data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        let tailSlices = trimmed.suffix(limit)
        let dec = JSONDecoder()
        var out: [SessionHarnessTaskRunRecord] = []
        out.reserveCapacity(tailSlices.count)
        for slice in tailSlices {
            if let row = try? dec.decode(SessionHarnessTaskRunRecord.self, from: Data(slice)) {
                out.append(row)
            }
        }
        return out
    }
}
