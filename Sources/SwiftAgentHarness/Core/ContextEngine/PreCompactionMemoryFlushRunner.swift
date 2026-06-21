import Foundation
import Logging
import SwiftAgentKit

struct PreCompactionMemoryFlushContext: Sendable {
    let conversationID: UUID
    let middleMessages: [Message]
    let maxFlushedMemoryEntries: Int
    let timeoutMs: Int
}

struct PreCompactionMemoryFlushResult: Sendable, Equatable {
    let succeeded: Bool
    let memoryStoreVersion: Int
    let flushedMemoryEntryIDs: [UUID]

    static let skipped = PreCompactionMemoryFlushResult(succeeded: false, memoryStoreVersion: 0, flushedMemoryEntryIDs: [])
}

protocol PreCompactionMemoryFlushRunning: Sendable {
    func runSilentFlushIfNeeded(
        context: PreCompactionMemoryFlushContext,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult
}

struct DefaultPreCompactionMemoryFlushRunner: PreCompactionMemoryFlushRunning {
    func runSilentFlushIfNeeded(
        context: PreCompactionMemoryFlushContext,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult {
        logger?.debug("[PreCompactionMemoryFlush] no memory service configured for conversation=\(context.conversationID)")
        return .skipped
    }
}
