import Foundation
import SwiftAgentKit

// MARK: - Preview result (returned to REST / clients)

struct ContextCompactionProvenanceEntry: Sendable, Codable, Equatable {
    let transformedMessageID: UUID
    let origin: String
    let sourceMessageIDs: [UUID]
}

/// Result of a **non-persisting** compaction run (harness / preview API). Does not update checkpoints or LLM cooldown state.
struct ContextCompactionPreviewResult: Sendable {
    let originalMessages: [Message]
    let compactedMessages: [Message]?
    let diagnostics: String?
    let messageProvenance: [ContextCompactionProvenanceEntry]?
    /// Set when the compaction LLM is not run (gating, disabled transform, etc.).
    let noopReason: String?
}

/// Result of a read-only full model-context projection (no persistence side effects).
struct ContextModelContextPreviewResult: Sendable {
    let originalMessages: [Message]
    let projectedMessages: [Message]
    let passthroughReason: String?
    let transformFailed: Bool
}

// MARK: - Manual compaction trigger + result

/// Identifies which manual surface initiated a compaction run. Used for logging and to gate
/// the "50% of threshold" refusal that only applies when the model itself called the tool.
enum ContextCompactionManualTrigger: String, Sendable {
    case modelTool = "model_tool"
    case slashCommand = "slash_command"
    case rest = "rest"
}

/// Result of a **persisting** manual compaction run (model tool, /compact slash, REST endpoint).
/// Successful runs write a checkpoint event and update the per-conversation cooldown timestamp,
/// matching the production agent-loop path.
struct ContextCompactionManualResult: Sendable {
    let trigger: ContextCompactionManualTrigger
    let conversationID: UUID
    let originalMessages: [Message]
    let compactedMessages: [Message]?
    let diagnostics: String?
    let messageProvenance: [ContextCompactionProvenanceEntry]?
    /// Reason from the input builder when no compaction LLM call was made (cooldown, transform disabled, etc.).
    let noopReason: String?
    /// Populated when the model-callable tool refuses because the conversation is below the
    /// `manualToolMinUtilization` gate. Other triggers never set this.
    let refusalReason: String?
    /// True when a checkpoint event was written and the cooldown timestamp updated.
    let persisted: Bool
    /// Resolved total prompt tokens at the time of the call (real count or estimate).
    let promptTokens: Int
    /// `proactiveThresholdTokens` at the time of the call.
    let thresholdTokens: Int
}

// MARK: - Gating (production vs preview)

/// Controls how the initial-phase path decides between passthrough and invoking the compaction transformer.
struct ContextCompactionGatingOptions: Sendable, Equatable {
    /// If true, skip the "middle under token threshold" early return (so the LLM can run on small transcripts).
    var ignoreTokenThreshold: Bool
    /// If true, skip cooldown and `middleMinCharactersForCompactionLLM` checks inside `shouldRunCompactionLLM` semantics.
    var forceRunCompactionLLM: Bool

    static let production = ContextCompactionGatingOptions(ignoreTokenThreshold: false, forceRunCompactionLLM: false)
    static let forcedReactiveRetry = ContextCompactionGatingOptions(
        ignoreTokenThreshold: true,
        forceRunCompactionLLM: true
    )
}

// MARK: - Build result (initial phase)

enum ContextCompactionInitialPhaseBuildResult: Sendable {
    /// Do not run the transformer; return the original `messages` as-is.
    case passthrough(reason: String)
    /// Run `ConversationTransforming.transformContext` with this input.
    case transform(ContextTransformInput)
}

// MARK: - Input builder

enum ContextCompactionInputBuilder: Sendable {

    // MARK: Initial phase (context compaction, checkpoints, token gate)

    static func buildInitialPhaseInput(
        messages: [Message],
        conversation: ModelConversation,
        transformMetadata: ConversationTransformMetadata,
        compactionConfig: ContextCompactionConfiguration,
        enableContextTransform: Bool,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        events: [CachedConversationEvent],
        eventLogFrontier: Int,
        lastLLMDateByConversationID: [UUID: Date],
        gating: ContextCompactionGatingOptions,
        compactionSummarizerDebugOutputPath: String? = nil,
        allowProactiveCompactionTriggers: Bool = true,
        sessionMemoryNoteForCompaction: String? = nil,
        compactionInjectedPrefix: [Message] = [],
        reinjectableSkills: [ReinjectableSkill] = [],
        postCompactionInstructionContext: String? = nil
    ) -> ContextCompactionInitialPhaseBuildResult {
        guard enableContextTransform else {
            return .passthrough(reason: "context_transform_disabled")
        }

        if compactionConfig.enabled,
           !allowProactiveCompactionTriggers,
           !gating.ignoreTokenThreshold {
            return .passthrough(reason: "proactive_compaction_disabled_for_mode")
        }

        let modelContextLimit = lastContextLimitTokens
            ?? conversation.model.maxContextLength
            ?? compactionConfig.fallbackContextLimitTokens
        let rawMiddle = ContextCompactionCheckpointSupport.rawMiddle(
            from: messages,
            config: compactionConfig,
            modelContextLimitTokens: modelContextLimit
        )
        let focusQuery = compactionConfig.focusedCompactionQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFocusQuery = focusQuery.isEmpty ? nil : focusQuery
        let strategy = ContextCompactionPolicy.resolvedStrategy(
            config: compactionConfig,
            branchParentConversationID: conversation.parentConversationID,
            explicitFocusQuery: resolvedFocusQuery
        )
        let cachePolicy = ContextCompactionPolicy.resolvedCachePolicy(config: compactionConfig)
        let deterministicHygienePolicy = ContextCompactionPolicy.resolvedDeterministicHygienePolicy(
            config: compactionConfig
        )
        let identifierPreservationPolicy = ContextCompactionPolicy.resolvedIdentifierPreservationPolicy(
            config: compactionConfig
        )
        let checkpointPair = LatestValidConversationCheckpoint.latestValidCompaction(
            events: events,
            rawMiddle: rawMiddle,
            config: compactionConfig,
            expectedCompactionStrategyRawValue: strategy.rawValue,
            frontierEventID: eventLogFrontier
        )
        let passEffectiveMiddle: [Message]? = checkpointPair.map { pair in
            ContextCompactionCheckpointSupport.effectiveMiddle(
                rawMiddle: rawMiddle,
                checkpoint: pair.payload
            ).middle
        }

        // Effective context limit reported on the input is the *agent vs summarizer floor*,
        // used for downstream metrics + UI; the trigger itself uses the raw model window.
        let effectiveContextLimit = ContextCompactionPolicy.effectiveContextLimitForCompactionTrigger(
            agentContextLimitTokens: modelContextLimit,
            summarizerContextLimitTokens: compactionConfig.compactionSummarizerContextLimitTokens
        )

        let exceedsTokenTrigger = ContextCompactionPolicy.proactiveTriggerFires(
            messages: compactionInjectedPrefix + messages,
            modelContextLimitTokens: modelContextLimit,
            lastActualPromptTokens: lastPromptTokens,
            config: compactionConfig
        )

        if compactionConfig.enabled,
           !gating.ignoreTokenThreshold,
           !exceedsTokenTrigger {
            return .passthrough(reason: "context_compaction_noop_under_token_threshold")
        }

        let canRunLLM: Bool
        if gating.forceRunCompactionLLM {
            canRunLLM = true
        } else {
            canRunLLM = ContextCompactionCheckpointSupport.shouldRunCompactionLLM(
                rawMiddle: rawMiddle,
                config: compactionConfig,
                conversationID: conversation.id,
                lastLLMDateByConversationID: lastLLMDateByConversationID
            )
        }

        if compactionConfig.enabled,
           (gating.ignoreTokenThreshold || exceedsTokenTrigger),
           !canRunLLM {
            return .passthrough(reason: "context_compaction_gated_cooldown_or_min_chars")
        }

        let previousSummaryText: String? = {
            guard let payload = checkpointPair?.payload,
                  payload.kind == .summarized,
                  let first = payload.syntheticMessages.first
            else { return nil }
            let body = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }()
        let input = ContextTransformInput(
            messages: compactionInjectedPrefix + messages,
            conversation: transformMetadata,
            phase: .initial,
            compactionEffectiveMiddle: passEffectiveMiddle,
            compactionRawMiddleMessages: rawMiddle,
            effectiveContextLimitTokens: effectiveContextLimit,
            compactionSummarizerDebugOutputPath: compactionSummarizerDebugOutputPath,
            compactionCheckpointKind: checkpointPair?.payload.kind,
            compactionCheckpointPrefixCount: checkpointPair?.payload.syntheticMessages.count,
            compactionModelContextLimitTokens: modelContextLimit,
            compactionLastPromptTokens: lastPromptTokens,
            compactionStrategy: strategy,
            compactionFocusQuery: resolvedFocusQuery,
            branchParentConversationID: conversation.parentConversationID,
            compactionCachePolicy: cachePolicy,
            compactionDeterministicHygienePolicy: deterministicHygienePolicy,
            compactionIdentifierPreservationPolicy: identifierPreservationPolicy,
            compactionPreviousSummaryText: previousSummaryText,
            compactionSessionMemoryNote: sessionMemoryNoteForCompaction,
            compactionSplitBaseMessages: messages,
            compactionInjectedPrefixMessages: compactionInjectedPrefix,
            compactionReinjectableSkills: reinjectableSkills,
            compactionPostCompactionInstructionContext: postCompactionInstructionContext
        )
        return .transform(input)
    }

    // MARK: Non-initial phases (agent continuations, etc.)

    static func buildNonInitialPhaseInput(
        messages: [Message],
        conversation: ModelConversation,
        transformMetadata: ConversationTransformMetadata,
        phase: ContextTransformInvocationPhase,
        compactionConfig: ContextCompactionConfiguration,
        lastContextLimitTokens: Int?
    ) -> ContextTransformInput {
        let agentContextLimit = lastContextLimitTokens
            ?? conversation.model.maxContextLength
            ?? compactionConfig.fallbackContextLimitTokens
        let effective = ContextCompactionPolicy.effectiveContextLimitForCompactionTrigger(
            agentContextLimitTokens: agentContextLimit,
            summarizerContextLimitTokens: compactionConfig.compactionSummarizerContextLimitTokens
        )
        return ContextTransformInput(
            messages: messages,
            conversation: transformMetadata,
            phase: phase,
            effectiveContextLimitTokens: effective,
            compactionStrategy: .default,
            compactionCachePolicy: ContextCompactionPolicy.resolvedCachePolicy(config: compactionConfig),
            compactionDeterministicHygienePolicy: ContextCompactionPolicy.resolvedDeterministicHygienePolicy(
                config: compactionConfig
            ),
            compactionIdentifierPreservationPolicy: ContextCompactionPolicy.resolvedIdentifierPreservationPolicy(
                config: compactionConfig
            )
        )
    }
}
