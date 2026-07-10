
//  Single orchestration path for CE ingest → assemble|compact → durable applicator.

import Foundation
import Logging
import SwiftAgentKit

/// Output of ``ContextAssemblyPipeline`` — **`HarnessRuntimeSession`** applies conversation-local hooks (topics, caches, snapshots).
struct ContextAssemblyPipelineRunOutput: Sendable {
    let assembleRequest: ContextEngineAssembleRequest
    let result: ContextEngineAssembleResult
    let persistenceEffects: ContextAssemblyPersistenceSideEffects
}

enum ContextAssemblyPipeline {
    /// Orchestrator turn path: **`ingestBatch`** → **`assemble`** → **`applyContextAssemblyPersistence`** (orchestrator scope).
    static func ingestAndOrchestratorAssemble(
        contextEngine: ContextEngine,
        persistenceDomain: ConversationPersistenceDomain,
        runtimeFacade: ContextAssemblyRuntimeFacade,
        conversationID: UUID,
        messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        gatingOverride: ContextCompactionGatingOptions?,
        allowProactiveCompactionTriggers: Bool,
        compactionLockAlreadyHeldByCaller: Bool,
        projectionPolicy: ContextEngineProjectionPolicyInput?,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        lastContextCompactionLLMDateByConversationID: [UUID: Date],
        logger: Logger?,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextAssemblyPipelineRunOutput {
        let hydratedMessages = await persistenceDomain.hydrateBlobImages(in: messages, conversationID: conversationID)
        // Lifecycle hook for alternate ContextEngine slots; default slot is a no-op.
        _ = await contextEngine.ingestBatch(
            request: ContextEngineIngestBatchRequest(conversationID: conversationID, messages: hydratedMessages)
        )
        let assembleRequest = await runtimeFacade.makeAssembleRequest(
            messages: hydratedMessages,
            conversation: conversation,
            phase: phase,
            gatingOverride: gatingOverride,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: compactionLockAlreadyHeldByCaller,
            projectionPolicy: projectionPolicy,
            lastContextLimitTokens: lastContextLimitTokens,
            lastPromptTokens: lastPromptTokens,
            lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID
        )
        let result = await contextEngine.assemble(request: assembleRequest, performTransform: performTransform)
        let persistenceEffects = await persistenceDomain.applyContextAssemblyPersistence(
            result: result,
            assembleRequest: assembleRequest,
            logger: logger,
            scope: .orchestratorAssemble,
            persistMemoryAndFlushCheckpoints: result.transformOutput != nil
                || result.preCompactionMemoryFlush != nil
        )
        return ContextAssemblyPipelineRunOutput(
            assembleRequest: assembleRequest,
            result: result,
            persistenceEffects: persistenceEffects
        )
    }

    /// Read-only orchestrator projection: same assemble path as production with `persistCompactionCheckpoint: false`
    /// and no durable applicator (transparency / debug preview).
    static func ingestAndOrchestratorAssemblePreview(
        contextEngine: ContextEngine,
        persistenceDomain: ConversationPersistenceDomain,
        runtimeFacade: ContextAssemblyRuntimeFacade,
        conversationID: UUID,
        messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        gatingOverride: ContextCompactionGatingOptions?,
        allowProactiveCompactionTriggers: Bool,
        projectionPolicy: ContextEngineProjectionPolicyInput?,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        lastContextCompactionLLMDateByConversationID: [UUID: Date],
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextAssemblyPipelineRunOutput {
        let hydratedMessages = await persistenceDomain.hydrateBlobImages(in: messages, conversationID: conversationID)
        // Lifecycle hook for alternate ContextEngine slots; default slot is a no-op.
        _ = await contextEngine.ingestBatch(
            request: ContextEngineIngestBatchRequest(conversationID: conversationID, messages: hydratedMessages)
        )
        let assembleRequest = await runtimeFacade.makeAssembleRequest(
            messages: hydratedMessages,
            conversation: conversation,
            phase: phase,
            gatingOverride: gatingOverride,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: false,
            projectionPolicy: projectionPolicy,
            lastContextLimitTokens: lastContextLimitTokens,
            lastPromptTokens: lastPromptTokens,
            lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID
        )
        let result = await contextEngine.assemble(request: assembleRequest, performTransform: performTransform)
        return ContextAssemblyPipelineRunOutput(
            assembleRequest: assembleRequest,
            result: result,
            persistenceEffects: ContextAssemblyPersistenceSideEffects(
                persistedCompactionCheckpoint: false,
                attachmentProjectionArtifactForCache: nil
            )
        )
    }

    /// Manual compaction path: **`ingestBatch`** → **`compact`** → **`applyContextAssemblyPersistence`** (manual scope).
    static func ingestAndManualCompact(
        contextEngine: ContextEngine,
        persistenceDomain: ConversationPersistenceDomain,
        runtimeFacade: ContextAssemblyRuntimeFacade,
        conversationID: UUID,
        messages: [Message],
        conversation: ModelConversation,
        compactionCustomInstructionsOverride: String?,
        compactionLockAlreadyHeldByCaller: Bool,
        projectionPolicy: ContextEngineProjectionPolicyInput?,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        lastContextCompactionLLMDateByConversationID: [UUID: Date],
        logger: Logger?,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextAssemblyPipelineRunOutput {
        let hydratedMessages = await persistenceDomain.hydrateBlobImages(in: messages, conversationID: conversationID)
        // Lifecycle hook for alternate ContextEngine slots; default slot is a no-op.
        _ = await contextEngine.ingestBatch(
            request: ContextEngineIngestBatchRequest(conversationID: conversationID, messages: hydratedMessages)
        )
        let assembleRequest = await runtimeFacade.makeAssembleRequest(
            messages: hydratedMessages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: .forcedReactiveRetry,
            compactionCustomInstructionsOverride: compactionCustomInstructionsOverride,
            enableContextTransform: true,
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: compactionLockAlreadyHeldByCaller,
            projectionPolicy: projectionPolicy,
            lastContextLimitTokens: lastContextLimitTokens,
            lastPromptTokens: lastPromptTokens,
            lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID
        )
        let compactRequest = ContextEngineCompactRequest(assemble: assembleRequest)
        let result = await contextEngine.compact(request: compactRequest, performTransform: performTransform)
        let persistenceEffects = await persistenceDomain.applyContextAssemblyPersistence(
            result: result,
            assembleRequest: assembleRequest,
            logger: logger,
            scope: .manualCompaction,
            persistMemoryAndFlushCheckpoints: true
        )
        return ContextAssemblyPipelineRunOutput(
            assembleRequest: assembleRequest,
            result: result,
            persistenceEffects: persistenceEffects
        )
    }
}
