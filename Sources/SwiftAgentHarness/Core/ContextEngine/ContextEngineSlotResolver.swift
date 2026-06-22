import Foundation
import Logging
import SwiftAgentKit

enum ContextEngineSlotID: String {
    case `default` = "default"
    case noop = "noop"
}

public enum ContextEngineSlotResolver {
    public static func resolve(
        slotID: String,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        logger: Logger?
    ) -> (any ContextEngine)? {
        guard let slot = ContextEngineSlotID(rawValue: slotID) else {
            logger?.warning("[ContextEngineSlotResolver] unknown slot '\(slotID)'; falling back to default engine")
            return nil
        }
        switch slot {
        case .default:
            return nil
        case .noop:
            return NoOpContextEngine()
        }
    }
}

struct NoOpContextEngine: ContextEngine {
    func bootstrap(request _: ContextEngineBootstrapRequest) async -> ContextEngineBootstrapResult {
        ContextEngineBootstrapResult(initialized: true)
    }

    func ingest(request _: ContextEngineIngestRequest) async -> ContextEngineIngestResult {
        ContextEngineIngestResult(ingestedCount: 1)
    }

    func ingestBatch(request: ContextEngineIngestBatchRequest) async -> ContextEngineIngestResult {
        ContextEngineIngestResult(ingestedCount: request.messages.count)
    }

    func assemble(
        request: ContextEngineAssembleRequest,
        performTransform _: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineAssembleResult {
        ContextEngineAssembleResult(
            messages: request.messages,
            transformOutput: nil,
            checkpointPersistence: nil,
            memoryInjectionSnapshot: nil,
            transformFailed: false,
            passthroughReason: "context_engine_noop_slot"
        )
    }

    func compact(
        request: ContextEngineCompactRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineCompactResult {
        let assembled = await assemble(request: request.assemble, performTransform: performTransform)
        return ContextEngineCompactResult(
            messages: assembled.messages,
            transformOutput: assembled.transformOutput,
            checkpointPersistence: assembled.checkpointPersistence,
            memoryInjectionSnapshot: assembled.memoryInjectionSnapshot,
            transformFailed: assembled.transformFailed,
            passthroughReason: assembled.passthroughReason
        )
    }

    func afterTurn(request _: ContextEngineAfterTurnRequest) async -> ContextEngineAfterTurnResult {
        ContextEngineAfterTurnResult(completed: true)
    }

    func prepareSubagentSpawn(
        request: ContextEnginePrepareSubagentSpawnRequest
    ) async -> ContextEnginePrepareSubagentSpawnResult {
        ContextEnginePrepareSubagentSpawnResult(approvedToolNames: request.candidateToolNames)
    }

    func onSubagentEnded(
        request _: ContextEngineSubagentEndedRequest
    ) async -> ContextEngineSubagentEndedResult {
        ContextEngineSubagentEndedResult(acknowledged: true)
    }
}
