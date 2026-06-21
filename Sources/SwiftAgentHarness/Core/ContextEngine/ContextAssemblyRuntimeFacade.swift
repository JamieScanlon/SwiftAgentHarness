import Foundation
import SwiftAgentKit

/// Runtime façade for building **`ContextEngineAssembleRequest`** and compaction locking — keeps **`HarnessRuntimeSession`** from owning projection-input plumbing (see **`CONTEXT_ASSEMBLY_BOUNDARY`** docs).
struct ContextAssemblyRuntimeFacade {
    let persistenceDomain: ConversationPersistenceDomain
    let conversationTransformConfiguration: ConversationTransformConfiguration

    func makeAssembleRequest(
        messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        gatingOverride: ContextCompactionGatingOptions?,
        compactionCustomInstructionsOverride: String?,
        enableContextTransform: Bool,
        persistCompactionCheckpoint: Bool,
        allowProactiveCompactionTriggers: Bool,
        compactionLockAlreadyHeldByCaller: Bool,
        projectionPolicy: ContextEngineProjectionPolicyInput?,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        lastContextCompactionLLMDateByConversationID: [UUID: Date]
    ) async -> ContextEngineAssembleRequest {
        await persistenceDomain.makeContextEngineAssembleRequest(
            messages: messages,
            conversation: conversation,
            phase: phase,
            gatingOverride: gatingOverride,
            compactionCustomInstructionsOverride: compactionCustomInstructionsOverride,
            enableContextTransform: enableContextTransform,
            persistCompactionCheckpoint: persistCompactionCheckpoint,
            allowProactiveCompactionTriggers: allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: compactionLockAlreadyHeldByCaller,
            projectionPolicy: projectionPolicy,
            lastContextLimitTokens: lastContextLimitTokens,
            lastPromptTokens: lastPromptTokens,
            lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
            conversationTransformConfiguration: conversationTransformConfiguration
        )
    }
}
