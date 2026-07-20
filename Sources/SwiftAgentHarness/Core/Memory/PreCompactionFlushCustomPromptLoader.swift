import Foundation
import Logging

enum PreCompactionFlushCustomPromptLoader: Sendable {
    /// Loads operator custom flush system prompt body from `path`. Returns nil when unset, missing, empty, or unreadable.
    static func load(path: String?, logger: Logger? = nil) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            logger?.debug("[PreCompactionMemoryFlush] custom system prompt unreadable at \(path)")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger?.debug("[PreCompactionMemoryFlush] custom system prompt empty at \(path)")
            return nil
        }
        return trimmed
    }
}
