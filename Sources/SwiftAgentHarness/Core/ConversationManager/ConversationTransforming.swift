import EasyJSON
import Foundation
import SwiftAgentKit

public enum ContextTransformInvocationPhase: Sendable {
    case initial
    case continuation(round: Int)
}

/// Persisted/config label for compaction summarizer behavior. The harness spec describes
/// techniques in ``summarization-techniques.md``; only ``default`` runs the full ``compaction.md``
/// pipeline. Other cases are aliases or narrow optional hooks—see per-case notes.
public enum ContextCompactionStrategy: String, Sendable, Codable {
    /// **Fully implemented.** Full compaction pipeline: token split, deterministic hygiene,
    /// session memory swap, summarizer (Ollama slot), REFERENCE ONLY framing, re-injection stub,
    /// derived + optional transcript compaction checkpoints. Includes iterative
    /// ``<previous-summary>`` when a summarized checkpoint exists, branch ``[BranchContext]``
    /// marker when ``branchParentConversationID`` is set, and focused prompt text only via
    /// manual compact (/compact, REST, tool)—not via this enum value.
    case `default`
    /// **Config alias only.** ``ContextCompactionPolicy/resolvedStrategy(config:branchParentConversationID:explicitFocusQuery:)``
    /// maps this to ``default``. Enabling ``iterative_delta`` in config therefore runs the same
    /// pipeline as ``default``, including prior-summary updates when a checkpoint exists.
    case iterativeDelta = "iterative_delta"
    /// **Config alias only.** Resolved to ``default``; no keyword middle filter. Focused compaction
    /// works only when manual compact passes ``compactionCustomInstructionsOverride``
    /// (slash command, REST ``reason``, model tool)—not when this enum is set in config.
    case focused
    /// **Partially implemented.** If selected in config (not aliased away), only trims the middle
    /// slice to the prefix through the last user message before hygiene/LLM. Spec turn-prefix
    /// summarization (separate smaller LLM for a mid-turn cut) is not implemented.
    case turnPrefix = "turn_prefix"
    /// **Partially implemented.** Prepends ``[BranchContext]`` system line to the middle when
    /// ``branchParentConversationID`` is set—the same marker ``default`` already applies on
    /// branch children. Spec branch summary on navigate-away (``recordTranscriptBranchSummary``)
    /// is persistence-only; not driven by this enum.
    case branchAware = "branch_aware"
}

public struct ContextCompactionCachePolicy: Sendable {
    public let enabled: Bool
    public let stablePrefixMessageCount: Int
    public let ttlSeconds: Double?

    public init(enabled: Bool, stablePrefixMessageCount: Int, ttlSeconds: Double?) {
        self.enabled = enabled
        self.stablePrefixMessageCount = stablePrefixMessageCount
        self.ttlSeconds = ttlSeconds
    }
}

public struct ContextCompactionAttachmentDocumentHygienePolicy: Sendable {
    public let enabled: Bool
    public let maxImagesPerMessage: Int
    public let documentCharacterThreshold: Int
    public let imagePlaceholder: String
    public let documentPlaceholder: String

    public init(
        enabled: Bool,
        maxImagesPerMessage: Int,
        documentCharacterThreshold: Int,
        imagePlaceholder: String,
        documentPlaceholder: String
    ) {
        self.enabled = enabled
        self.maxImagesPerMessage = maxImagesPerMessage
        self.documentCharacterThreshold = documentCharacterThreshold
        self.imagePlaceholder = imagePlaceholder
        self.documentPlaceholder = documentPlaceholder
    }
}

public struct ContextCompactionDeterministicHygienePolicy: Sendable {
    public let toolResultPruningEnabled: Bool
    public let attachmentDocumentHygiene: ContextCompactionAttachmentDocumentHygienePolicy

    public init(
        toolResultPruningEnabled: Bool,
        attachmentDocumentHygiene: ContextCompactionAttachmentDocumentHygienePolicy
    ) {
        self.toolResultPruningEnabled = toolResultPruningEnabled
        self.attachmentDocumentHygiene = attachmentDocumentHygiene
    }
}

public enum ContextCompactionIdentifierPreservationMode: String, Sendable {
    case strict
    case custom
    case off
}

public struct ContextCompactionIdentifierPreservationPolicy: Sendable {
    public let mode: ContextCompactionIdentifierPreservationMode
    public let customInstructions: String?

    public init(mode: ContextCompactionIdentifierPreservationMode, customInstructions: String?) {
        self.mode = mode
        self.customInstructions = customInstructions
    }
}

public struct ConversationTransformMetadata: Sendable {
    let conversationID: UUID
    let modelID: String
    let modelName: String
    let interactionMode: InteractionMode
    let routingPolicyTools: [String]
    let routingPolicySkills: [String]
    let thinkingConfig: ThinkingConfig?
    let metadata: JSON?

    init(
        conversationID: UUID,
        modelID: String,
        modelName: String,
        interactionMode: InteractionMode,
        routingPolicyTools: [String],
        routingPolicySkills: [String],
        thinkingConfig: ThinkingConfig? = nil,
        metadata: JSON?
    ) {
        self.conversationID = conversationID
        self.modelID = modelID
        self.modelName = modelName
        self.interactionMode = interactionMode
        self.routingPolicyTools = routingPolicyTools
        self.routingPolicySkills = routingPolicySkills
        self.thinkingConfig = thinkingConfig
        self.metadata = metadata
    }

    init(
        conversationID: UUID,
        modelID: String,
        modelName: String,
        interactionMode: InteractionMode,
        routingPolicyTools: [String],
        routingPolicySkills: [String],
        thinkingEnabled: Bool,
        reasoningEffort: ConversationReasoningEffort?,
        metadata: JSON?
    ) {
        let thinkingConfig: ThinkingConfig?
        if let reasoningEffort {
            switch reasoningEffort {
            case .none:
                thinkingConfig = .level(.off, budgetTokens: nil)
            case .minimal:
                thinkingConfig = .level(.minimal, budgetTokens: nil)
            case .low:
                thinkingConfig = .level(.low, budgetTokens: nil)
            case .medium:
                thinkingConfig = .level(.medium, budgetTokens: nil)
            case .high:
                thinkingConfig = .level(.high, budgetTokens: nil)
            }
        } else {
            thinkingConfig = thinkingEnabled ? .adaptive : .disabled
        }
        self.init(
            conversationID: conversationID,
            modelID: modelID,
            modelName: modelName,
            interactionMode: interactionMode,
            routingPolicyTools: routingPolicyTools,
            routingPolicySkills: routingPolicySkills,
            thinkingConfig: thinkingConfig,
            metadata: metadata
        )
    }
}

/// An active skill resolved for post-compaction re-injection: its name and full instruction body.
/// Resolved upstream (e.g. by ``DefaultContextEngine`` via the configured ``SkillLoader``) so the
/// synchronous re-injection collector can budget and truncate it without filesystem or actor access.
public struct ReinjectableSkill: Sendable, Equatable {
    public let name: String
    public let content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }
}

public struct ContextTransformInput: Sendable {
    let messages: [Message]
    let conversation: ConversationTransformMetadata
    let phase: ContextTransformInvocationPhase
    /// When non-nil, compaction uses this as the **middle** for the LLM (checkpoint synthesis + raw tail). `messages` remains the full raw base transcript.
    let compactionEffectiveMiddle: [Message]?
    /// Ordered raw middle messages from the base transcript (for provenance and checkpoint persistence). Defaults to deriving from `messages` when nil.
    let compactionRawMiddleMessages: [Message]?
    /// Resolved context window in tokens (last LLM snapshot, then model, then config fallback). Used for token-based compaction eligibility on `.initial`.
    let effectiveContextLimitTokens: Int?
    /// When non-nil (e.g. ContextCompactionLab `POST .../preview-context-compaction` only), compaction summarizer writes debug `summarizer-input.md` / `summarizer-output.md` under a time-stamped subfolder of this path. Production transforms pass `nil`.
    let compactionSummarizerDebugOutputPath: String?
    /// One-shot override for the summarizer's `compactionCustomInstructionsBlock` (manual triggers
    /// can pass a free-form `reason` here). Never persisted to the configuration; lives only for
    /// this single `transformContext` call. State-hygiene invariant: callers that want the configured
    /// block must pass `nil` (the default).
    let compactionCustomInstructionsOverride: String?
    /// When the latest valid checkpoint is being applied to `compactionEffectiveMiddle`, this is
    /// its `kind`. Drives the transformer branching: `.summarized` checkpoints process only the
    /// new raw tail; `.pruned` checkpoints skip the deterministic prune step. `nil` means no
    /// reusable checkpoint exists and the transformer runs the full flow.
    let compactionCheckpointKind: ContextCompactionCheckpointKind?
    /// Number of leading messages in `compactionEffectiveMiddle` that come from the prior
    /// checkpoint's synthesized payload (the rest are the new raw tail). `nil` when no checkpoint
    /// is being reused. Used by the transformer to split effective middle into prior synth and
    /// new raw tail without re-deriving from raw IDs.
    let compactionCheckpointPrefixCount: Int?
    /// Raw model context window (in tokens) used by the transformer's post-prune
    /// short-circuit threshold check. Falls back to `config.fallbackContextLimitTokens` when nil.
    let compactionModelContextLimitTokens: Int?
    /// Most recent observed prompt token count from the LLM provider for the conversation. Used
    /// by the post-prune threshold check; falls back to estimation when nil.
    let compactionLastPromptTokens: Int?
    /// Selected advanced summarization strategy for this transform pass.
    let compactionStrategy: ContextCompactionStrategy
    /// Optional focused compaction query/task scope.
    let compactionFocusQuery: String?
    /// Parent conversation when running on a branch child (for branch-aware strategies).
    let branchParentConversationID: UUID?
    /// Cache-aware pruning policy for this pass.
    let compactionCachePolicy: ContextCompactionCachePolicy?
    /// Deterministic pre-summarizer hygiene policy (tool-result + attachment/document/image stages).
    let compactionDeterministicHygienePolicy: ContextCompactionDeterministicHygienePolicy?
    /// Identifier-preservation prompt policy for compaction summarizer (`strict` / `custom` / `off`).
    let compactionIdentifierPreservationPolicy: ContextCompactionIdentifierPreservationPolicy?
    /// Prior summarized checkpoint body for iterative `<previous-summary>` updates.
    let compactionPreviousSummaryText: String?
    /// Pre-compaction session memory note for middle swap (spec stage 3).
    let compactionSessionMemoryNote: String?
    /// Aggregated memory provider `onPreCompress` notes for the compaction summarizer handoff prompt.
    let compactionProviderPreCompressNotes: String?
    /// Filtered transcript used for head/middle/tail split and checkpoint validity (excludes harness injections).
    let compactionSplitBaseMessages: [Message]?
    /// Harness-injected system messages prepended to split head in transformer output.
    let compactionInjectedPrefixMessages: [Message]?
    /// Active skills (name + content) resolved upstream for budgeted post-compaction re-injection.
    let compactionReinjectableSkills: [ReinjectableSkill]
    /// Tool names whose compaction hygiene must never clear tool-result content (e.g. sub-agent delegates).
    let compactionProtectedToolNames: Set<String>

    init(
        messages: [Message],
        conversation: ConversationTransformMetadata,
        phase: ContextTransformInvocationPhase,
        compactionEffectiveMiddle: [Message]? = nil,
        compactionRawMiddleMessages: [Message]? = nil,
        effectiveContextLimitTokens: Int? = nil,
        compactionSummarizerDebugOutputPath: String? = nil,
        compactionCustomInstructionsOverride: String? = nil,
        compactionCheckpointKind: ContextCompactionCheckpointKind? = nil,
        compactionCheckpointPrefixCount: Int? = nil,
        compactionModelContextLimitTokens: Int? = nil,
        compactionLastPromptTokens: Int? = nil,
        compactionStrategy: ContextCompactionStrategy = .default,
        compactionFocusQuery: String? = nil,
        branchParentConversationID: UUID? = nil,
        compactionCachePolicy: ContextCompactionCachePolicy? = nil,
        compactionDeterministicHygienePolicy: ContextCompactionDeterministicHygienePolicy? = nil,
        compactionIdentifierPreservationPolicy: ContextCompactionIdentifierPreservationPolicy? = nil,
        compactionPreviousSummaryText: String? = nil,
        compactionSessionMemoryNote: String? = nil,
        compactionProviderPreCompressNotes: String? = nil,
        compactionSplitBaseMessages: [Message]? = nil,
        compactionInjectedPrefixMessages: [Message]? = nil,
        compactionReinjectableSkills: [ReinjectableSkill] = [],
        compactionProtectedToolNames: Set<String> = []
    ) {
        self.messages = messages
        self.conversation = conversation
        self.phase = phase
        self.compactionEffectiveMiddle = compactionEffectiveMiddle
        self.compactionRawMiddleMessages = compactionRawMiddleMessages
        self.effectiveContextLimitTokens = effectiveContextLimitTokens
        self.compactionSummarizerDebugOutputPath = compactionSummarizerDebugOutputPath
        self.compactionCustomInstructionsOverride = compactionCustomInstructionsOverride
        self.compactionCheckpointKind = compactionCheckpointKind
        self.compactionCheckpointPrefixCount = compactionCheckpointPrefixCount
        self.compactionModelContextLimitTokens = compactionModelContextLimitTokens
        self.compactionLastPromptTokens = compactionLastPromptTokens
        self.compactionStrategy = compactionStrategy
        self.compactionFocusQuery = compactionFocusQuery
        self.branchParentConversationID = branchParentConversationID
        self.compactionCachePolicy = compactionCachePolicy
        self.compactionDeterministicHygienePolicy = compactionDeterministicHygienePolicy
        self.compactionIdentifierPreservationPolicy = compactionIdentifierPreservationPolicy
        self.compactionPreviousSummaryText = compactionPreviousSummaryText
        self.compactionSessionMemoryNote = compactionSessionMemoryNote
        self.compactionProviderPreCompressNotes = compactionProviderPreCompressNotes
        self.compactionSplitBaseMessages = compactionSplitBaseMessages
        self.compactionInjectedPrefixMessages = compactionInjectedPrefixMessages
        self.compactionReinjectableSkills = compactionReinjectableSkills
        self.compactionProtectedToolNames = compactionProtectedToolNames
    }

    func withCompactionProviderPreCompressNotes(_ notes: String?) -> ContextTransformInput {
        ContextTransformInput(
            messages: messages,
            conversation: conversation,
            phase: phase,
            compactionEffectiveMiddle: compactionEffectiveMiddle,
            compactionRawMiddleMessages: compactionRawMiddleMessages,
            effectiveContextLimitTokens: effectiveContextLimitTokens,
            compactionSummarizerDebugOutputPath: compactionSummarizerDebugOutputPath,
            compactionCustomInstructionsOverride: compactionCustomInstructionsOverride,
            compactionCheckpointKind: compactionCheckpointKind,
            compactionCheckpointPrefixCount: compactionCheckpointPrefixCount,
            compactionModelContextLimitTokens: compactionModelContextLimitTokens,
            compactionLastPromptTokens: compactionLastPromptTokens,
            compactionStrategy: compactionStrategy,
            compactionFocusQuery: compactionFocusQuery,
            branchParentConversationID: branchParentConversationID,
            compactionCachePolicy: compactionCachePolicy,
            compactionDeterministicHygienePolicy: compactionDeterministicHygienePolicy,
            compactionIdentifierPreservationPolicy: compactionIdentifierPreservationPolicy,
            compactionPreviousSummaryText: compactionPreviousSummaryText,
            compactionSessionMemoryNote: compactionSessionMemoryNote,
            compactionProviderPreCompressNotes: notes,
            compactionSplitBaseMessages: compactionSplitBaseMessages,
            compactionInjectedPrefixMessages: compactionInjectedPrefixMessages,
            compactionReinjectableSkills: compactionReinjectableSkills,
            compactionProtectedToolNames: compactionProtectedToolNames
        )
    }
}

enum ContextTransformedMessageOrigin: String, Sendable {
    case original
    case synthesized
    case reinjected
}

public struct ContextTransformMessageProvenance: Sendable {
    let transformedMessageID: UUID
    let origin: ContextTransformedMessageOrigin
    /// Original conversation message IDs that this transformed message came from.
    let sourceMessageIDs: [UUID]
}

public struct ContextTransformOutput: Sendable {
    let messages: [Message]
    let diagnostics: String?
    let messageProvenance: [ContextTransformMessageProvenance]?
    /// Standalone summary for checkpoint persistence when layout omits a middle slice (e.g. merge into tail).
    let compactionPersistedMiddle: [Message]?

    init(
        messages: [Message],
        diagnostics: String?,
        messageProvenance: [ContextTransformMessageProvenance]?,
        compactionPersistedMiddle: [Message]? = nil
    ) {
        self.messages = messages
        self.diagnostics = diagnostics
        self.messageProvenance = messageProvenance
        self.compactionPersistedMiddle = compactionPersistedMiddle
    }
}

public struct TurnSummaryTransformInput: Sendable {
    let conversation: ConversationTransformMetadata
    let turnMessageRangeStartIndex: Int
    let turnMessages: [Message]
}

public struct TurnSummaryTransformOutput: Sendable {
    /// Full replacement payload for the turn segment `turnMessages`.
    let replacementTurnMessages: [Message]
    let diagnostics: String?
}

public protocol ConversationTransforming: Sendable {
    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput
    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput
}

public struct NoOpConversationTransformer: ConversationTransforming {
    public init() {}

    public func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        ContextTransformOutput(
            messages: input.messages,
            diagnostics: nil,
            messageProvenance: input.messages.map { message in
                ContextTransformMessageProvenance(
                    transformedMessageID: message.id,
                    origin: .original,
                    sourceMessageIDs: [message.id]
                )
            }
        )
    }

    public func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        TurnSummaryTransformOutput(replacementTurnMessages: input.turnMessages, diagnostics: nil)
    }
}
