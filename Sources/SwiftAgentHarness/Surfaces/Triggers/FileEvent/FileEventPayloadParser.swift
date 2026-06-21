import Foundation
import Logging

enum FileEventParseResult: Sendable, Equatable {
    case parsed(FileEventPayload)
    case skipped
}

struct FileEventPayloadParser: Sendable {
    let logger: Logger
    let backoffMilliseconds: [Int]
    let sleep: @Sendable (Int) async -> Void

    init(
        logger: Logger,
        backoffMilliseconds: [Int] = FileEventQueueWatcher.parseRetryBackoffMilliseconds,
        sleep: @escaping @Sendable (Int) async -> Void = { ms in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
    ) {
        self.logger = logger
        self.backoffMilliseconds = backoffMilliseconds
        self.sleep = sleep
    }

    func parse(at url: URL) async -> FileEventParseResult {
        for (attempt, delay) in backoffMilliseconds.enumerated() {
            if let data = try? Data(contentsOf: url),
               let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data) {
                return .parsed(payload)
            }
            if attempt < backoffMilliseconds.count - 1 {
                await sleep(delay)
            }
        }
        if let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data) {
            return .parsed(payload)
        }
        logger.warning("file_event_parse_skipped path=\(url.lastPathComponent)")
        return .skipped
    }
}
