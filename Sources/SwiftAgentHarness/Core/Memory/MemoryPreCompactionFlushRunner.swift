import Foundation
import Logging

struct MemoryPreCompactionFlushRunner: PreCompactionMemoryFlushRunning {
    let memoryService: DefaultMemoryService
    let logger: Logger?

    func runSilentFlushIfNeeded(
        context: PreCompactionMemoryFlushContext,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult {
        let log = logger ?? self.logger
        guard !context.middleMessages.isEmpty else {
            log?.debug("[PreCompactionMemoryFlush] skipped: empty middle conversation=\(context.conversationID)")
            return .skipped
        }
        guard let port = await memoryService.spawnPort() else {
            log?.warning("[PreCompactionMemoryFlush] skipped: spawn port unbound conversation=\(context.conversationID)")
            return .skipped
        }
        log?.info("[PreCompactionMemoryFlush] conversation=\(context.conversationID) middleMessages=\(context.middleMessages.count)")
        return await memoryService.runPreCompactionFlush(context: context, spawnPort: port, logger: log)
    }
}
