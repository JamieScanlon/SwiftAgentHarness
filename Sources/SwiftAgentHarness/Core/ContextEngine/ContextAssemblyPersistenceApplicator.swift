import Foundation
import Logging

/// Which derived checkpoints to persist after **`ContextEngine`** **`assemble`** / **`compact`**.
enum ContextAssemblyDerivedCheckpointScope: Sendable {
    /// Orchestrator **`assemble`** path: memory injection + pre-flush (when transform or flush-only produced output), system prompt assembly, attachment projection, compaction.
    case orchestratorAssemble
    /// **`compact`** / manual compaction: memory injection, pre-flush, compaction only (matches historical **`performManualCompaction`**).
    case manualCompaction
}

/// Side effects surfaced to **`HarnessRuntimeSession`** after durable CE checkpoint application.
struct ContextAssemblyPersistenceSideEffects: Sendable {
    let persistedCompactionCheckpoint: Bool
    /// When non-nil, caller should merge into **`lastAttachmentProjectionByConversationID`** (orchestrator path).
    let attachmentProjectionArtifactForCache: ContextEngineAttachmentProjectionArtifact?
    /// When non-nil, caller should merge into **`lastSystemPromptAssemblyByConversationID`** (orchestrator path).
    let systemPromptAssemblyArtifactForCache: ContextEngineSystemPromptAssemblyArtifact?
}

/// Single place to apply ``ContextCheckpointWriter`` after a ``ContextEngineAssembleResult``.
enum ContextAssemblyPersistenceApplicator {
    /// Persists derived checkpoints produced by **`assemble`** / **`compact`**.
    static func apply(
        result: ContextEngineAssembleResult,
        assembleRequest: ContextEngineAssembleRequest,
        persistence: ConversationPersistenceStack,
        logger: Logger?,
        scope: ContextAssemblyDerivedCheckpointScope,
        /// When false, skips memory injection + pre-compaction flush rows (orchestrator passthrough with no flush).
        persistMemoryAndFlushCheckpoints: Bool
    ) -> ContextAssemblyPersistenceSideEffects {
        switch scope {
        case .orchestratorAssemble:
            if persistMemoryAndFlushCheckpoints {
                ContextCheckpointWriter.persistMemoryInjectionSnapshotCheckpointIfNeeded(
                    spec: result.memoryInjectionSnapshot,
                    events: assembleRequest.events,
                    frontierEventID: assembleRequest.eventLogFrontier,
                    persistence: persistence,
                    logger: logger
                )
                if let output = result.transformOutput {
                    ContextCheckpointWriter.persistMemoryInjectionSnapshotCheckpointIfNeeded(
                        conversationID: assembleRequest.conversation.id,
                        phase: assembleRequest.phase,
                        output: output,
                        events: assembleRequest.events,
                        frontierEventID: assembleRequest.eventLogFrontier,
                        persistence: persistence,
                        logger: logger
                    )
                }
                ContextCheckpointWriter.persistPreCompactionMemoryFlushCheckpointIfNeeded(
                    spec: result.preCompactionMemoryFlush,
                    events: assembleRequest.events,
                    frontierEventID: assembleRequest.eventLogFrontier,
                    persistence: persistence,
                    logger: logger
                )
            }
            ContextCheckpointWriter.persistSystemPromptAssemblyCheckpointIfNeeded(
                spec: result.systemPromptCheckpoint,
                persistence: persistence,
                logger: logger
            )
            ContextCheckpointWriter.persistAttachmentProjectionCheckpointIfNeeded(
                spec: result.attachmentProjectionCheckpoint,
                events: assembleRequest.events,
                frontierEventID: assembleRequest.eventLogFrontier,
                persistence: persistence,
                logger: logger
            )
            let attachmentCache = result.projectionArtifact?.attachmentProjection
            let systemPromptCache = result.projectionArtifact?.systemPromptAssembly
            let persistedCompaction = ContextCheckpointWriter.persistCompactionCheckpointIfNeeded(
                spec: result.checkpointPersistence,
                persistence: persistence,
                logger: logger
            )
            return ContextAssemblyPersistenceSideEffects(
                persistedCompactionCheckpoint: persistedCompaction,
                attachmentProjectionArtifactForCache: attachmentCache,
                systemPromptAssemblyArtifactForCache: systemPromptCache
            )

        case .manualCompaction:
            ContextCheckpointWriter.persistMemoryInjectionSnapshotCheckpointIfNeeded(
                spec: result.memoryInjectionSnapshot,
                events: assembleRequest.events,
                frontierEventID: assembleRequest.eventLogFrontier,
                persistence: persistence,
                logger: logger
            )
            if let output = result.transformOutput {
                ContextCheckpointWriter.persistMemoryInjectionSnapshotCheckpointIfNeeded(
                    conversationID: assembleRequest.conversation.id,
                    phase: assembleRequest.phase,
                    output: output,
                    events: assembleRequest.events,
                    frontierEventID: assembleRequest.eventLogFrontier,
                    persistence: persistence,
                    logger: logger
                )
            }
            ContextCheckpointWriter.persistPreCompactionMemoryFlushCheckpointIfNeeded(
                spec: result.preCompactionMemoryFlush,
                events: assembleRequest.events,
                frontierEventID: assembleRequest.eventLogFrontier,
                persistence: persistence,
                logger: logger
            )
            let persistedCompaction = ContextCheckpointWriter.persistCompactionCheckpointIfNeeded(
                spec: result.checkpointPersistence,
                persistence: persistence,
                logger: logger
            )
            return ContextAssemblyPersistenceSideEffects(
                persistedCompactionCheckpoint: persistedCompaction,
                attachmentProjectionArtifactForCache: nil,
                systemPromptAssemblyArtifactForCache: nil
            )
        }
    }
}
