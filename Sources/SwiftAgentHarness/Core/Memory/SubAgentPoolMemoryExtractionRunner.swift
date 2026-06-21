import Foundation
import Logging

struct SubAgentPoolMemoryExtractionRunner: MemoryExtractionRunning {
    private let spawnPort: MemorySubAgentSpawnPort
    private let config: MemoryConfiguration
    private let logger: Logger?

    init(spawnPort: MemorySubAgentSpawnPort, config: MemoryConfiguration, logger: Logger? = nil) {
        self.spawnPort = spawnPort
        self.config = config
        self.logger = logger
    }

    func startBackgroundExtraction(request: MemoryTurnEndedRequest) async {
        guard config.extractionEnabled else { return }
        logger?.debug("[MemoryExtractor] scheduling background extraction conversation=\(request.session.conversationID.uuidString)")
        await spawnPort.spawnBackgroundExtraction(request)
    }
}
