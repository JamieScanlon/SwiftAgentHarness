import Foundation

struct ToolResultSpillWriteResult: Sendable, Equatable {
    let fileURL: URL
    let byteCount: Int
    let created: Bool
}

struct SessionToolResultSpillStore: Sendable {
    let root: URL
    let agentId: String

    func spillDirectoryURL(conversationId: UUID) -> URL {
        SessionPersistenceLayout.toolResultsDirectory(root: root, agentId: agentId, conversationId: conversationId)
    }

    func spillFileURL(conversationId: UUID, toolCallId: String) -> URL {
        SessionPersistenceLayout.toolResultSpillFileURL(
            root: root,
            agentId: agentId,
            conversationId: conversationId,
            toolCallId: toolCallId
        )
    }

    /// Idempotent spill: returns existing file when byte count matches.
    func putIfNeeded(
        conversationId: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult {
        let data = Data(content.utf8)
        let destination = spillFileURL(conversationId: conversationId, toolCallId: toolCallId)
        let directory = destination.deletingLastPathComponent()
        try SessionPersistenceLayout.ensureDirectory(directory)
        if FileManager.default.fileExists(atPath: destination.path),
           let existing = try? Data(contentsOf: destination),
           existing == data {
            return ToolResultSpillWriteResult(fileURL: destination, byteCount: data.count, created: false)
        }
        let temporary = directory.appendingPathComponent(".spill-\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return ToolResultSpillWriteResult(fileURL: destination, byteCount: data.count, created: true)
    }

    func isAllowlistedSpillPath(_ path: String, conversationId: UUID) -> Bool {
        let spillRoot = spillDirectoryURL(conversationId: conversationId).path
        let resolved = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
        guard resolved.hasPrefix(spillRoot + "/") || resolved == spillRoot else {
            return false
        }
        return true
    }
}
