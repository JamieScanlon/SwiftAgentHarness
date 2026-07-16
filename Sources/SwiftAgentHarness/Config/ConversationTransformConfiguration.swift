import Foundation
import Logging

public struct ContextCompactionConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var ollamaServerURL: URL
    public var model: String
    /// Used when the model’s context limit is unknown and no recent LLM metadata snapshot exists.
    public var fallbackContextLimitTokens: Int
    /// Heuristic: UTF-8 bytes per token for `ContextCompactionPolicy.estimatedTotalPromptTokens`.
    public var charactersPerToken: Double
    /// Cap on synthesized middle messages passed to the compaction LLM (system + final preserved separately).
    public var maxCompactedMiddleMessages: Int
    /// If greater than zero, skip compaction LLM when the middle segment has fewer total characters than this (soft “under budget” gate).
    public var middleMinCharactersForCompactionLLM: Int
    /// If greater than zero, skip compaction LLM if another call happened within this many seconds for the same conversation (unless gates are disabled by setting to `0`).
    public var compactionLLMCooldownSeconds: Double
    /// When non-empty, `role == .tool` messages for these tool names (resolved from prior assistant `toolCalls` via `toolCallId`) are passed to the compaction summarizer with `content` replaced by the standard cleared placeholder; other fields are unchanged. Does not affect stored conversation messages.
    public var compactionToolResultPruneNames: [String]
    /// Recency cap for tool results whose tool name is **not** in `compactionToolResultPruneNames`: at most this many resolvable unlisted `tool` messages still carry real content, counting from the end of the middle segment; older ones are cleared the same way. See `ContextCompactionToolResultPruning`.
    public var maxRecentToolResults: Int
    /// Recency cap for tool results whose tool name **is** in `compactionToolResultPruneNames`, applied **per name independently**: e.g. with `["web-fetch", "web-search"]` and a value of `5` the pruned middle keeps the last 5 `web-fetch` and the last 5 `web-search` results, clearing earlier ones. See `ContextCompactionToolResultPruning`.
    public var maxRecentPerNameToolResults: Int
    /// Replacement-content strategy for tool results dropped during pre-compaction hygiene: `.blankMarker` substitutes the content-free placeholder (rung 1), `.oneLineSummary` substitutes a deterministic 1-line summary that preserves the key signal at zero cost (rung 2). Affects only the compaction LLM payload; stored conversation messages are unchanged. See `ContextCompactionToolResultPruning` and `DeterministicToolResultSummary`.
    public var toolResultPruneReplacementMode: ToolResultPruneReplacementMode
    /// Target size hint (in tokens) for the `<summary>` body, substituted as `{{summary_budget}}` in the compaction user prompt template.
    public var compactionSummaryBudgetTokens: Int
    /// Optional site- or deployment-specific instructions appended to the compaction user prompt as `{{custom_instructions_block}}`.
    public var compactionCustomInstructionsBlock: String
    /// Identifier-preservation mode for compaction summarizer prompt contract (`strict` / `custom` / `off`).
    public var compactionIdentifierPreservationMode: String
    /// Optional custom identifier-preservation instructions when mode is `custom`.
    public var compactionIdentifierPreservationCustomInstructions: String
    /// Max context size (tokens) of the compaction / summarizer LLM. Used as a floor on the agent context window for the trigger threshold.
    public var compactionSummarizerContextLimitTokens: Int
    /// Proactive trigger: tokens of headroom kept beneath `effective_context_window` before triggering. `effective_context_window = model_context_window − proactiveOutputReserveTokens`; trigger fires when total prompt tokens > `effective_context_window − proactiveSafetyBufferTokens`.
    public var proactiveSafetyBufferTokens: Int
    /// Proactive trigger: tokens reserved for the model's own output, subtracted from the model context window before applying `proactiveSafetyBufferTokens`.
    public var proactiveOutputReserveTokens: Int
    /// Reactive trigger: when `true`, a context-window-exceeded error from the orchestrator forces a single in-turn compaction retry.
    public var reactiveTriggerEnabled: Bool
    /// Substring patterns matched (case-insensitively) against thrown error descriptions to identify a provider "context window exceeded" failure. Shared by reactive trigger and oversize-retry loop.
    public var reactiveErrorPatterns: [String]
    /// Oversize-retry: maximum attempts inside `OllamaContextCompactionSummarizer.summarizeMiddle` when the summarizer LLM itself returns a context-window error. Includes the initial attempt.
    public var oversizeRetryMaxAttempts: Int
    /// Oversize-retry: fraction (0…1) of the oldest message groups to drop from the working middle on each retry attempt.
    public var oversizeRetryDropFraction: Double
    /// Oversize-retry: synthetic user marker prepended to the working middle on each shrink. Tells the next attempt that earlier history was truncated.
    public var oversizeRetryMarker: String
    /// Manual trigger: when `true`, the model-callable `compact_conversation` tool is registered with the orchestrator.
    public var manualToolEnabled: Bool
    /// Manual trigger: minimum fraction of `proactiveThresholdTokens` the conversation must already exceed for the model-callable tool to compact (0…1). Prevents the model from compacting a fresh conversation.
    public var manualToolMinUtilization: Double
    /// Manual trigger: when `true`, `sendMessageAndStreamResponse` intercepts `/compact` (and `/compact <reason>`) before saving the user message.
    public var manualSlashEnabled: Bool
    /// Manual trigger: when `true`, `POST /api/conversations/:id/compact` is registered (still requires the same token gate as the preview endpoint).
    public var manualRESTEnabled: Bool
    /// Optional non-default strategy (`turn_prefix`, `branch_aware`, etc.); `default` is spec-aligned compaction.
    public var defaultSummarizationStrategy: String
    /// Default focused-compaction query; empty means no persistent focus query.
    public var focusedCompactionQuery: String
    /// Enables deterministic cache-aware pruning before summarizer invocation.
    public var cacheAwarePruningEnabled: Bool
    /// Number of leading middle messages retained to maximize cache-stable prefix reuse.
    public var cacheStablePrefixMessageCount: Int
    /// Optional TTL for middle messages in cache-aware pruning stage (`nil` / `<=0` disables age pruning).
    public var cachePruningTTLSeconds: Double?
    /// Projection-time context pruning mode (`off`, `cacheTTL`). When unset, derived from `cacheAwarePruningEnabled`.
    public var contextPruningMode: String?
    /// Number of most recent tool results to keep when TTL pruning runs at assemble/projection time.
    public var contextPruningKeepRecentToolResults: Int
    /// Optional tool-name filter for TTL pruning; `nil` means all eligible tools.
    public var contextPruningTargetTools: [String]?
    /// Idle gap (seconds) after the last foreground model request before inferring the prompt cache
    /// is dead and batching deferred hygiene. `nil` uses the default (9000s / 2.5h).
    public var cacheExpiryInferenceThresholdSeconds: Double?
    /// Deterministic stage toggle for tool-result pruning before summarizer invocation.
    public var deterministicToolResultPruningEnabled: Bool
    /// Enables deterministic attachment/image/document hygiene before summarizer invocation.
    public var deterministicAttachmentDocumentHygieneEnabled: Bool
    /// Per-message image cap applied when deterministic attachment/document hygiene is enabled.
    public var deterministicMaxImagesPerMessage: Int
    /// Character threshold for classifying long text blobs as document-like payloads.
    public var deterministicDocumentCharacterThreshold: Int
    /// Placeholder used when document-like payload content is replaced by deterministic hygiene.
    public var deterministicDocumentPlaceholder: String
    /// Max UTF-8 preview bytes included in document hygiene receipts.
    public var deterministicDocumentPreviewMaxBytes: Int
    /// Placeholder used when image attachments are trimmed by deterministic hygiene.
    public var deterministicImagePlaceholder: String
    /// Optional pre-compaction memory flush stage before summarization.
    public var preCompactionMemoryFlushEnabled: Bool
    /// Max number of memory entries included in a pre-compaction flush snapshot.
    public var preCompactionMemoryFlushMaxEntries: Int
    /// Token headroom below the hard proactive threshold for a flush-only soft pass.
    /// `0` disables soft flush (flush only on the hard compaction path).
    public var softThresholdTokens: Int
    /// Optional compaction provider slot id (e.g. `ollama`, `none`). `nil` means default provider.
    public var optionalCompactionProviderSlot: String?
    /// When true, provider errors fall back to the default Ollama provider chain.
    public var optionalCompactionProviderFallbackToOllama: Bool
    public var headMinMessageCount: Int
    public var tailMinMessageCount: Int
    public var tailTokenBudgetFraction: Double
    public var compactionSummarizerMaxOutputTokens: Int
    public var compactionSummaryBudgetProportionalEnabled: Bool
    public var sessionMemorySwapBeforeCompactionEnabled: Bool
    public var compactionReinjectionEnabled: Bool
    /// Number of most-recently-accessed files considered for post-compaction re-injection.
    public var reinjectionRecentFileCount: Int
    /// Per-file token budget for re-injected file content (`compaction.md` target: 5k/file).
    public var reinjectionPerFileTokenBudget: Int
    /// Total token budget across all re-injected files (`compaction.md` target: 50k total).
    public var reinjectionTotalFileTokenBudget: Int
    /// Per-skill token budget for re-injected active-skill content (`compaction.md` target: 5k/skill).
    public var reinjectionPerSkillTokenBudget: Int
    /// Total token budget across all re-injected skills (`compaction.md` target: 25k total).
    public var reinjectionTotalSkillTokenBudget: Int
    /// When true (default), re-inject the recent files' truncated content (spec primary). When false,
    /// fall back to the path-only list (re-read with tools), the spec's cheaper alternative.
    public var reinjectFileContentEnabled: Bool
    /// When true (default), re-inject named H2/H3 sections from the nearest project instruction file after compaction.
    public var reinjectionInstructionSectionsEnabled: Bool
    /// H2/H3 section names to extract (default: Session Startup + Red Lines).
    public var reinjectionInstructionSectionNames: [String]
    /// Total character budget for re-injected instruction sections (OpenClaw default: 3000).
    public var reinjectionInstructionSectionMaxCharacters: Int
    public var compactionCircuitBreakerMaxFailures: Int
    /// Minimum fractional prompt-token reduction required to persist a compaction checkpoint (0 = disabled).
    public var compactionMinPromptTokenSavingsFraction: Double
    public var useSessionTreeProjection: Bool

    public static let defaultReactiveErrorPatterns: [String] = [
        "prompt too long",
        "context length",
        "maximum context",
        "context window",
        "too many tokens",
        "too large for the model",
    ]

    public static let defaultOversizeRetryMarker: String =
        "[earlier conversation truncated for compaction retry]"

    /// Slack multiplier shared with checkpoint persistence size guards.
    public static let checkpointPersistenceSizeSlack = 1.5

    /// Spec's summarizer output reserve (`compaction.md`, "Target sizes"): a healthy post-compact
    /// context reserves 20k tokens for the summary itself. Acts as the floor for the summarizer's
    /// `max_tokens` and the persistence ceiling so summaries are never truncated below the reserve.
    public static let summaryOutputReserveTokens = 20_000

    /// Largest summary budget the resolver can choose: the proportional cap (`12k`) when proportional
    /// budgeting is enabled, otherwise the fixed budget. Mirrors `ContextCompactionPolicy.resolvedSummaryBudgetTokens`.
    public var proportionalSummaryBudgetCeiling: Int {
        compactionSummaryBudgetProportionalEnabled ? 12_000 : compactionSummaryBudgetTokens
    }

    /// Token ceiling for persisted compaction summaries. Tracks the resolved (proportional-aware)
    /// budget and never falls below the 20k output reserve, so an enabled proportional budget — and
    /// the spec's reserve — are actually emittable and persistable.
    public var compactionPersistenceTokenCeiling: Int {
        Int(
            Double(max(compactionSummaryBudgetTokens, proportionalSummaryBudgetCeiling, Self.summaryOutputReserveTokens))
                * Self.checkpointPersistenceSizeSlack
        )
    }

    /// Summarizer LLM `maxTokens`: capped by the persistence ceiling but floored at the 20k reserve so
    /// it never clamps below the spec target. Invariant: `>= resolvedSummaryBudgetTokens` and `>= 20k`.
    public var resolvedSummarizerMaxOutputTokens: Int {
        max(Self.summaryOutputReserveTokens, min(compactionSummarizerMaxOutputTokens, compactionPersistenceTokenCeiling))
    }

    public static let `default` = ContextCompactionConfiguration(
        enabled: true,
        ollamaServerURL: URL(string: "http://localhost:11434")!,
        model: "gemma4:e4b",
        fallbackContextLimitTokens: 131_072,
        charactersPerToken: 4,
        maxCompactedMiddleMessages: 15,
        middleMinCharactersForCompactionLLM: 0,
        compactionLLMCooldownSeconds: 0,
        compactionToolResultPruneNames: [],
        maxRecentToolResults: 5,
        maxRecentPerNameToolResults: 5,
        toolResultPruneReplacementMode: .oneLineSummary,
        compactionSummaryBudgetTokens: 2000,
        compactionCustomInstructionsBlock: "",
        compactionIdentifierPreservationMode: "strict",
        compactionIdentifierPreservationCustomInstructions: "",
        compactionSummarizerContextLimitTokens: 131_072,
        proactiveSafetyBufferTokens: 13_000,
        proactiveOutputReserveTokens: 20_000,
        reactiveTriggerEnabled: true,
        reactiveErrorPatterns: defaultReactiveErrorPatterns,
        oversizeRetryMaxAttempts: 3,
        oversizeRetryDropFraction: 0.2,
        oversizeRetryMarker: defaultOversizeRetryMarker,
        manualToolEnabled: true,
        manualToolMinUtilization: 0.5,
        manualSlashEnabled: true,
        manualRESTEnabled: true,
        defaultSummarizationStrategy: "default",
        focusedCompactionQuery: "",
        cacheAwarePruningEnabled: false,
        cacheStablePrefixMessageCount: 4,
        cachePruningTTLSeconds: nil,
        contextPruningMode: nil,
        contextPruningKeepRecentToolResults: 5,
        contextPruningTargetTools: nil,
        cacheExpiryInferenceThresholdSeconds: nil,
        deterministicToolResultPruningEnabled: true,
        deterministicAttachmentDocumentHygieneEnabled: false,
        deterministicMaxImagesPerMessage: 3,
        deterministicDocumentCharacterThreshold: 12_000,
        deterministicDocumentPlaceholder: "[Document content cleared for context compaction]",
        deterministicDocumentPreviewMaxBytes: 2048,
        deterministicImagePlaceholder: "[Image attachment omitted for context compaction]",
        preCompactionMemoryFlushEnabled: true,
        preCompactionMemoryFlushMaxEntries: 64,
        softThresholdTokens: 8_000,
        optionalCompactionProviderSlot: nil,
        optionalCompactionProviderFallbackToOllama: true,
        headMinMessageCount: 3,
        tailMinMessageCount: 6,
        tailTokenBudgetFraction: 0.2,
        compactionSummarizerMaxOutputTokens: 20_000,
        compactionSummaryBudgetProportionalEnabled: true,
        sessionMemorySwapBeforeCompactionEnabled: true,
        compactionReinjectionEnabled: true,
        reinjectionRecentFileCount: 5,
        reinjectionPerFileTokenBudget: 5_000,
        reinjectionTotalFileTokenBudget: 50_000,
        reinjectionPerSkillTokenBudget: 5_000,
        reinjectionTotalSkillTokenBudget: 25_000,
        reinjectFileContentEnabled: true,
        reinjectionInstructionSectionsEnabled: true,
        reinjectionInstructionSectionNames: ["Session Startup", "Red Lines"],
        reinjectionInstructionSectionMaxCharacters: 3_000,
        compactionCircuitBreakerMaxFailures: 3,
        compactionMinPromptTokenSavingsFraction: 0.03,
        useSessionTreeProjection: true
    )

    public init(
        enabled: Bool,
        ollamaServerURL: URL,
        model: String,
        fallbackContextLimitTokens: Int = 131_072,
        charactersPerToken: Double = 4,
        maxCompactedMiddleMessages: Int = 15,
        middleMinCharactersForCompactionLLM: Int = 0,
        compactionLLMCooldownSeconds: Double = 0,
        compactionToolResultPruneNames: [String] = [],
        maxRecentToolResults: Int = 5,
        maxRecentPerNameToolResults: Int = 5,
        toolResultPruneReplacementMode: ToolResultPruneReplacementMode = .oneLineSummary,
        compactionSummaryBudgetTokens: Int = 2000,
        compactionCustomInstructionsBlock: String = "",
        compactionIdentifierPreservationMode: String = "strict",
        compactionIdentifierPreservationCustomInstructions: String = "",
        compactionSummarizerContextLimitTokens: Int = 131_072,
        proactiveSafetyBufferTokens: Int = 13_000,
        proactiveOutputReserveTokens: Int = 20_000,
        reactiveTriggerEnabled: Bool = true,
        reactiveErrorPatterns: [String] = ContextCompactionConfiguration.defaultReactiveErrorPatterns,
        oversizeRetryMaxAttempts: Int = 3,
        oversizeRetryDropFraction: Double = 0.2,
        oversizeRetryMarker: String = ContextCompactionConfiguration.defaultOversizeRetryMarker,
        manualToolEnabled: Bool = true,
        manualToolMinUtilization: Double = 0.5,
        manualSlashEnabled: Bool = true,
        manualRESTEnabled: Bool = true,
        defaultSummarizationStrategy: String = "default",
        focusedCompactionQuery: String = "",
        cacheAwarePruningEnabled: Bool = false,
        cacheStablePrefixMessageCount: Int = 4,
        cachePruningTTLSeconds: Double? = nil,
        contextPruningMode: String? = nil,
        contextPruningKeepRecentToolResults: Int = 5,
        contextPruningTargetTools: [String]? = nil,
        cacheExpiryInferenceThresholdSeconds: Double? = nil,
        deterministicToolResultPruningEnabled: Bool = true,
        deterministicAttachmentDocumentHygieneEnabled: Bool = false,
        deterministicMaxImagesPerMessage: Int = 3,
        deterministicDocumentCharacterThreshold: Int = 12_000,
        deterministicDocumentPlaceholder: String = "[Document content cleared for context compaction]",
        deterministicDocumentPreviewMaxBytes: Int = 2048,
        deterministicImagePlaceholder: String = "[Image attachment omitted for context compaction]",
        preCompactionMemoryFlushEnabled: Bool = true,
        preCompactionMemoryFlushMaxEntries: Int = 64,
        softThresholdTokens: Int = 8_000,
        optionalCompactionProviderSlot: String? = nil,
        optionalCompactionProviderFallbackToOllama: Bool = true,
        headMinMessageCount: Int = 3,
        tailMinMessageCount: Int = 6,
        tailTokenBudgetFraction: Double = 0.2,
        compactionSummarizerMaxOutputTokens: Int = 20_000,
        compactionSummaryBudgetProportionalEnabled: Bool = true,
        sessionMemorySwapBeforeCompactionEnabled: Bool = true,
        compactionReinjectionEnabled: Bool = true,
        reinjectionRecentFileCount: Int = 5,
        reinjectionPerFileTokenBudget: Int = 5_000,
        reinjectionTotalFileTokenBudget: Int = 50_000,
        reinjectionPerSkillTokenBudget: Int = 5_000,
        reinjectionTotalSkillTokenBudget: Int = 25_000,
        reinjectFileContentEnabled: Bool = true,
        reinjectionInstructionSectionsEnabled: Bool = true,
        reinjectionInstructionSectionNames: [String] = ["Session Startup", "Red Lines"],
        reinjectionInstructionSectionMaxCharacters: Int = 3_000,
        compactionCircuitBreakerMaxFailures: Int = 3,
        compactionMinPromptTokenSavingsFraction: Double = 0.03,
        useSessionTreeProjection: Bool = true
    ) {
        self.enabled = enabled
        self.ollamaServerURL = ollamaServerURL
        self.model = model
        self.fallbackContextLimitTokens = fallbackContextLimitTokens
        self.charactersPerToken = charactersPerToken
        self.maxCompactedMiddleMessages = maxCompactedMiddleMessages
        self.middleMinCharactersForCompactionLLM = middleMinCharactersForCompactionLLM
        self.compactionLLMCooldownSeconds = compactionLLMCooldownSeconds
        self.compactionToolResultPruneNames = compactionToolResultPruneNames
        self.maxRecentToolResults = maxRecentToolResults
        self.maxRecentPerNameToolResults = maxRecentPerNameToolResults
        self.toolResultPruneReplacementMode = toolResultPruneReplacementMode
        self.compactionSummaryBudgetTokens = compactionSummaryBudgetTokens
        self.compactionCustomInstructionsBlock = compactionCustomInstructionsBlock
        self.compactionIdentifierPreservationMode = compactionIdentifierPreservationMode
        self.compactionIdentifierPreservationCustomInstructions = compactionIdentifierPreservationCustomInstructions
        self.compactionSummarizerContextLimitTokens = compactionSummarizerContextLimitTokens
        self.proactiveSafetyBufferTokens = proactiveSafetyBufferTokens
        self.proactiveOutputReserveTokens = proactiveOutputReserveTokens
        self.reactiveTriggerEnabled = reactiveTriggerEnabled
        self.reactiveErrorPatterns = reactiveErrorPatterns
        self.oversizeRetryMaxAttempts = oversizeRetryMaxAttempts
        self.oversizeRetryDropFraction = oversizeRetryDropFraction
        self.oversizeRetryMarker = oversizeRetryMarker
        self.manualToolEnabled = manualToolEnabled
        self.manualToolMinUtilization = manualToolMinUtilization
        self.manualSlashEnabled = manualSlashEnabled
        self.manualRESTEnabled = manualRESTEnabled
        self.defaultSummarizationStrategy = defaultSummarizationStrategy
        self.focusedCompactionQuery = focusedCompactionQuery
        self.cacheAwarePruningEnabled = cacheAwarePruningEnabled
        self.cacheStablePrefixMessageCount = cacheStablePrefixMessageCount
        self.cachePruningTTLSeconds = cachePruningTTLSeconds
        self.contextPruningMode = contextPruningMode
        self.contextPruningKeepRecentToolResults = contextPruningKeepRecentToolResults
        self.contextPruningTargetTools = contextPruningTargetTools
        self.cacheExpiryInferenceThresholdSeconds = cacheExpiryInferenceThresholdSeconds
        self.deterministicToolResultPruningEnabled = deterministicToolResultPruningEnabled
        self.deterministicAttachmentDocumentHygieneEnabled = deterministicAttachmentDocumentHygieneEnabled
        self.deterministicMaxImagesPerMessage = deterministicMaxImagesPerMessage
        self.deterministicDocumentCharacterThreshold = deterministicDocumentCharacterThreshold
        self.deterministicDocumentPlaceholder = deterministicDocumentPlaceholder
        self.deterministicDocumentPreviewMaxBytes = max(0, deterministicDocumentPreviewMaxBytes)
        self.deterministicImagePlaceholder = deterministicImagePlaceholder
        self.preCompactionMemoryFlushEnabled = preCompactionMemoryFlushEnabled
        self.preCompactionMemoryFlushMaxEntries = preCompactionMemoryFlushMaxEntries
        self.softThresholdTokens = softThresholdTokens
        self.optionalCompactionProviderSlot = optionalCompactionProviderSlot
        self.optionalCompactionProviderFallbackToOllama = optionalCompactionProviderFallbackToOllama
        self.headMinMessageCount = headMinMessageCount
        self.tailMinMessageCount = tailMinMessageCount
        self.tailTokenBudgetFraction = tailTokenBudgetFraction
        self.compactionSummarizerMaxOutputTokens = compactionSummarizerMaxOutputTokens
        self.compactionSummaryBudgetProportionalEnabled = compactionSummaryBudgetProportionalEnabled
        self.sessionMemorySwapBeforeCompactionEnabled = sessionMemorySwapBeforeCompactionEnabled
        self.compactionReinjectionEnabled = compactionReinjectionEnabled
        self.reinjectionRecentFileCount = reinjectionRecentFileCount
        self.reinjectionPerFileTokenBudget = reinjectionPerFileTokenBudget
        self.reinjectionTotalFileTokenBudget = reinjectionTotalFileTokenBudget
        self.reinjectionPerSkillTokenBudget = reinjectionPerSkillTokenBudget
        self.reinjectionTotalSkillTokenBudget = reinjectionTotalSkillTokenBudget
        self.reinjectFileContentEnabled = reinjectFileContentEnabled
        self.reinjectionInstructionSectionsEnabled = reinjectionInstructionSectionsEnabled
        self.reinjectionInstructionSectionNames = reinjectionInstructionSectionNames
        self.reinjectionInstructionSectionMaxCharacters = reinjectionInstructionSectionMaxCharacters
        self.compactionCircuitBreakerMaxFailures = compactionCircuitBreakerMaxFailures
        self.compactionMinPromptTokenSavingsFraction = compactionMinPromptTokenSavingsFraction
        self.useSessionTreeProjection = useSessionTreeProjection
    }
}

public struct SlashCommandConfiguration: Sendable, Equatable {
    public struct ToolDispatchCommand: Sendable, Equatable {
        public var command: String
        public var toolName: String
        public var argMode: SlashToolDispatchArgMode
        public var description: String
        public var argumentHint: String?
        public var hiddenKeywords: String
        public var aliases: [String]
        public var ownerOnly: Bool
        public var bypassTier: SlashCommandBypassTier
        public var enabled: Bool

        public init(
            command: String,
            toolName: String,
            argMode: SlashToolDispatchArgMode = .raw,
            description: String,
            argumentHint: String? = nil,
            hiddenKeywords: String = "",
            aliases: [String] = [],
            ownerOnly: Bool = false,
            bypassTier: SlashCommandBypassTier = .queued,
            enabled: Bool = true
        ) {
            self.command = command
            self.toolName = toolName
            self.argMode = argMode
            self.description = description
            self.argumentHint = argumentHint
            self.hiddenKeywords = hiddenKeywords
            self.aliases = aliases
            self.ownerOnly = ownerOnly
            self.bypassTier = bypassTier
            self.enabled = enabled
        }
    }

    /// Global slash-command processing toggle. When false, all `/...` input is treated as plain user text.
    public var enabled: Bool
    /// Preserve historical behavior: unknown commands pass through to the model as normal text.
    public var allowUnknownPassthrough: Bool
    /// Per-command enable flag for `/compact` runtime handling.
    public var compactEnabled: Bool
    /// When false, `/skill:…` user invocations are ignored for slash handling (passthrough as plain text).
    public var skillSlashEnabled: Bool
    /// When false, turn-tuning directives (`/think`, `/model`, …) are treated as plain text.
    public var directivesEnabled: Bool
    /// When false, inline shortcuts (`/help`, `/status` + prose) are treated as plain text.
    public var inlineShortcutsEnabled: Bool
    /// Directive names requiring owner authorization (lowercased, without leading `/`).
    public var ownerOnlyDirectiveNames: [String]
    /// Optional static slash rows that dispatch directly to named tools.
    public var toolDispatchCommands: [ToolDispatchCommand]
    /// Skill directory names (lowercased) that already have a dedicated top-level slash entry; excluded from merged `/skill:` autocomplete rows only.
    public var staticSkillNamesExcludedFromSkillColon: [String]

    public static let `default` = SlashCommandConfiguration(
        enabled: true,
        allowUnknownPassthrough: true,
        compactEnabled: true,
        skillSlashEnabled: true,
        directivesEnabled: true,
        inlineShortcutsEnabled: true,
        ownerOnlyDirectiveNames: ["model"],
        toolDispatchCommands: [],
        staticSkillNamesExcludedFromSkillColon: []
    )

    public init(
        enabled: Bool = true,
        allowUnknownPassthrough: Bool = true,
        compactEnabled: Bool = true,
        skillSlashEnabled: Bool = true,
        directivesEnabled: Bool = true,
        inlineShortcutsEnabled: Bool = true,
        ownerOnlyDirectiveNames: [String] = ["model"],
        toolDispatchCommands: [ToolDispatchCommand] = [],
        staticSkillNamesExcludedFromSkillColon: [String] = []
    ) {
        self.enabled = enabled
        self.allowUnknownPassthrough = allowUnknownPassthrough
        self.compactEnabled = compactEnabled
        self.skillSlashEnabled = skillSlashEnabled
        self.directivesEnabled = directivesEnabled
        self.inlineShortcutsEnabled = inlineShortcutsEnabled
        self.ownerOnlyDirectiveNames = ownerOnlyDirectiveNames
        self.toolDispatchCommands = toolDispatchCommands
        self.staticSkillNamesExcludedFromSkillColon = staticSkillNamesExcludedFromSkillColon
    }
}

public struct ToolResultFormattingConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var spillEnabled: Bool
    public var spillPreviewMaxBytes: Int
    public var defaultMaxResultSizeBeforeSpill: Int
    public var runtimeMaxCharacters: Int
    public var persistenceMaxCharacters: Int
    public var compactionMaxCharacters: Int
    public var runtimeMaxBytes: Int
    public var persistenceMaxBytes: Int
    public var compactionMaxBytes: Int
    public var runtimeMetadataMaxBytes: Int
    public var persistenceMetadataMaxBytes: Int
    public var compactionMetadataMaxBytes: Int
    public var maxLines: Int
    public var sanitizeInlineImagePayloads: Bool
    public var maxInlineImagePixelDimension: Int
    public var maxInlineImageBytes: Int
    public var imagePayloadPlaceholder: String
    public var compactionImagePayloadPlaceholder: String
    public var metadataPlaceholder: String
    public var compactionMetadataPlaceholder: String
    public var truncationMarker: String
    public var compactionTruncationMarker: String

    public static let `default` = ToolResultFormattingConfiguration(
        enabled: true,
        spillEnabled: SessionPersistenceConfiguration.harnessOnDiskV2Configured,
        spillPreviewMaxBytes: 2_048,
        defaultMaxResultSizeBeforeSpill: 480_000,
        runtimeMaxCharacters: 120_000,
        persistenceMaxCharacters: 300_000,
        compactionMaxCharacters: 40_000,
        runtimeMaxBytes: 480_000,
        persistenceMaxBytes: 1_200_000,
        compactionMaxBytes: 160_000,
        runtimeMetadataMaxBytes: 96_000,
        persistenceMetadataMaxBytes: 256_000,
        compactionMetadataMaxBytes: 64_000,
        maxLines: 800,
        sanitizeInlineImagePayloads: true,
        maxInlineImagePixelDimension: 1_200,
        maxInlineImageBytes: 5_000_000,
        imagePayloadPlaceholder: "[inline image payload omitted]",
        compactionImagePayloadPlaceholder: "[old image payload replaced for compaction]",
        metadataPlaceholder: "[tool metadata omitted]",
        compactionMetadataPlaceholder: "[old tool metadata replaced for compaction]",
        truncationMarker: "[tool result truncated]",
        compactionTruncationMarker: "[old tool payload replaced for compaction]"
    )

    public init(
        enabled: Bool = true,
        spillEnabled: Bool = SessionPersistenceConfiguration.harnessOnDiskV2Configured,
        spillPreviewMaxBytes: Int = 2_048,
        defaultMaxResultSizeBeforeSpill: Int = 480_000,
        runtimeMaxCharacters: Int = 120_000,
        persistenceMaxCharacters: Int = 300_000,
        compactionMaxCharacters: Int = 40_000,
        runtimeMaxBytes: Int = 480_000,
        persistenceMaxBytes: Int = 1_200_000,
        compactionMaxBytes: Int = 160_000,
        runtimeMetadataMaxBytes: Int = 96_000,
        persistenceMetadataMaxBytes: Int = 256_000,
        compactionMetadataMaxBytes: Int = 64_000,
        maxLines: Int = 800,
        sanitizeInlineImagePayloads: Bool = true,
        maxInlineImagePixelDimension: Int = 1_200,
        maxInlineImageBytes: Int = 5_000_000,
        imagePayloadPlaceholder: String = "[inline image payload omitted]",
        compactionImagePayloadPlaceholder: String = "[old image payload replaced for compaction]",
        metadataPlaceholder: String = "[tool metadata omitted]",
        compactionMetadataPlaceholder: String = "[old tool metadata replaced for compaction]",
        truncationMarker: String = "[tool result truncated]",
        compactionTruncationMarker: String = "[old tool payload replaced for compaction]"
    ) {
        self.enabled = enabled
        self.spillEnabled = spillEnabled
        self.spillPreviewMaxBytes = max(0, spillPreviewMaxBytes)
        self.defaultMaxResultSizeBeforeSpill = max(0, defaultMaxResultSizeBeforeSpill)
        self.runtimeMaxCharacters = max(0, runtimeMaxCharacters)
        self.persistenceMaxCharacters = max(0, persistenceMaxCharacters)
        self.compactionMaxCharacters = max(0, compactionMaxCharacters)
        self.runtimeMaxBytes = max(0, runtimeMaxBytes)
        self.persistenceMaxBytes = max(0, persistenceMaxBytes)
        self.compactionMaxBytes = max(0, compactionMaxBytes)
        self.runtimeMetadataMaxBytes = max(0, runtimeMetadataMaxBytes)
        self.persistenceMetadataMaxBytes = max(0, persistenceMetadataMaxBytes)
        self.compactionMetadataMaxBytes = max(0, compactionMetadataMaxBytes)
        self.maxLines = max(0, maxLines)
        self.sanitizeInlineImagePayloads = sanitizeInlineImagePayloads
        self.maxInlineImagePixelDimension = max(0, maxInlineImagePixelDimension)
        self.maxInlineImageBytes = max(0, maxInlineImageBytes)
        self.imagePayloadPlaceholder = imagePayloadPlaceholder
        self.compactionImagePayloadPlaceholder = compactionImagePayloadPlaceholder
        self.metadataPlaceholder = metadataPlaceholder
        self.compactionMetadataPlaceholder = compactionMetadataPlaceholder
        self.truncationMarker = truncationMarker
        self.compactionTruncationMarker = compactionTruncationMarker
    }
}

/// Per-`InteractionMode` toggles for the three conversation transform hooks (context, tool result, turn summary).
public struct TransformHookToggles: Sendable, Equatable {
    public var enableContextTransform: Bool
    public var enableToolResultTransform: Bool
    public var enableTurnSummaryTransform: Bool

    public static let allEnabled = TransformHookToggles(
        enableContextTransform: true,
        enableToolResultTransform: true,
        enableTurnSummaryTransform: true
    )

    public init(
        enableContextTransform: Bool,
        enableToolResultTransform: Bool,
        enableTurnSummaryTransform: Bool
    ) {
        self.enableContextTransform = enableContextTransform
        self.enableToolResultTransform = enableToolResultTransform
        self.enableTurnSummaryTransform = enableTurnSummaryTransform
    }
}

/// Optional `conversationTransforms` block in PromptConfig.json.
public struct ConversationTransformConfiguration: Sendable, Equatable {
    public var chat: TransformHookToggles
    public var plan: TransformHookToggles
    public var agent: TransformHookToggles
    public var transformTimeoutSeconds: Double
    public var contextCompaction: ContextCompactionConfiguration
    public var slashCommands: SlashCommandConfiguration
    public var toolResultFormatting: ToolResultFormattingConfiguration

    public static let `default` = ConversationTransformConfiguration(
        chat: .allEnabled,
        plan: .allEnabled,
        agent: .allEnabled,
        transformTimeoutSeconds: 1800,
        contextCompaction: .default,
        slashCommands: .default,
        toolResultFormatting: .default
    )

    public init(
        chat: TransformHookToggles,
        plan: TransformHookToggles,
        agent: TransformHookToggles,
        transformTimeoutSeconds: Double,
        contextCompaction: ContextCompactionConfiguration = .default,
        slashCommands: SlashCommandConfiguration = .default,
        toolResultFormatting: ToolResultFormattingConfiguration = .default
    ) {
        self.chat = chat
        self.plan = plan
        self.agent = agent
        self.transformTimeoutSeconds = transformTimeoutSeconds
        self.contextCompaction = contextCompaction
        self.slashCommands = slashCommands
        self.toolResultFormatting = toolResultFormatting
    }

    public func toggles(for interactionMode: InteractionMode) -> TransformHookToggles {
        switch interactionMode {
        case .chat:
            return chat
        case .plan:
            return plan
        case .agent:
            return agent
        }
    }

    public static func load(from document: PromptConfigDocument, logger: Logger? = nil) -> ConversationTransformConfiguration {
        guard let block = document.foundationObject(forKey: "conversationTransforms") else {
            return .default
        }
        return configuration(fromJSON: block)
    }

    @available(*, deprecated, message: "Pass HarnessConfigurationSet or load(from: PromptConfigDocument)")

    internal static func configuration(fromJSON block: [String: Any]) -> ConversationTransformConfiguration {
        func bool(_ key: String, default def: Bool) -> Bool {
            if let v = block[key] as? Bool { return v }
            return def
        }
        func timeout(_ key: String, default def: Double) -> Double {
            if let v = block[key] as? Double { return min(3600.0, max(1.0, v)) }
            if let v = block[key] as? Int { return min(3600.0, max(1.0, Double(v))) }
            return def
        }
        func contextCompaction(_ key: String, default def: ContextCompactionConfiguration) -> ContextCompactionConfiguration {
            guard let payload = block[key] as? [String: Any] else {
                return def
            }
            let enabled = (payload["enabled"] as? Bool) ?? def.enabled
            let model = {
                if let value = payload["model"] as? String, !value.isEmpty {
                    return value
                }
                return def.model
            }()
            let ollamaURL = {
                if let text = payload["ollamaServerURL"] as? String, let url = URL(string: text) {
                    return url
                }
                return def.ollamaServerURL
            }()
            let fallbackContextLimitTokens = {
                if let value = payload["fallbackContextLimitTokens"] as? Int {
                    return Swift.min(8_388_608, Swift.max(1024, value))
                }
                return def.fallbackContextLimitTokens
            }()
            let charactersPerToken = {
                if let value = payload["charactersPerToken"] as? Double {
                    return Swift.min(32, Swift.max(1, value))
                }
                if let value = payload["charactersPerToken"] as? Int {
                    return Swift.min(32, Swift.max(1, Double(value)))
                }
                return def.charactersPerToken
            }()
            let maxCompactedMiddleMessages = {
                if let value = payload["maxCompactedMiddleMessages"] as? Int {
                    return Swift.min(200, Swift.max(3, value))
                }
                return def.maxCompactedMiddleMessages
            }()
            let middleMinCharactersForCompactionLLM = {
                if let value = payload["middleMinCharactersForCompactionLLM"] as? Int {
                    return Swift.min(2_000_000, Swift.max(0, value))
                }
                return def.middleMinCharactersForCompactionLLM
            }()
            let compactionLLMCooldownSeconds = {
                if let value = payload["compactionLLMCooldownSeconds"] as? Double {
                    return Swift.min(86_400.0, Swift.max(0, value))
                }
                if let value = payload["compactionLLMCooldownSeconds"] as? Int {
                    return Swift.min(86_400.0, Swift.max(0, Double(value)))
                }
                return def.compactionLLMCooldownSeconds
            }()
            let compactionToolResultPruneNames: [String] = {
                if let arr = payload["compactionToolResultPruneNames"] as? [String] {
                    return arr
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                return def.compactionToolResultPruneNames
            }()
            let maxRecentToolResults: Int = {
                let raw: Int? = {
                    if let v = payload["maxRecentToolResults"] as? Int { return v }
                    if let v = payload["max_recent_tool_results"] as? Int { return v }
                    return nil
                }()
                guard let v = raw else { return def.maxRecentToolResults }
                return Swift.min(1_000_000, Swift.max(0, v))
            }()
            let maxRecentPerNameToolResults: Int = {
                let raw: Int? = {
                    if let v = payload["maxRecentPerNameToolResults"] as? Int { return v }
                    if let v = payload["max_recent_per_name_tool_results"] as? Int { return v }
                    return nil
                }()
                guard let v = raw else { return def.maxRecentPerNameToolResults }
                return Swift.min(1_000_000, Swift.max(0, v))
            }()
            let toolResultPruneReplacementMode: ToolResultPruneReplacementMode = {
                let raw = (payload["toolResultPruneReplacementMode"] as? String)
                    ?? (payload["tool_result_prune_replacement_mode"] as? String)
                switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "blank", "blankmarker", "blank_marker":
                    return .blankMarker
                case "one_line_summary", "onelinesummary":
                    return .oneLineSummary
                default:
                    return def.toolResultPruneReplacementMode
                }
            }()
            let compactionSummaryBudgetTokens: Int = {
                if let value = payload["compactionSummaryBudgetTokens"] as? Int {
                    return Swift.min(1_000_000, Swift.max(1, value))
                }
                return def.compactionSummaryBudgetTokens
            }()
            let compactionCustomInstructionsBlock: String = {
                if let value = payload["compactionCustomInstructionsBlock"] as? String {
                    return value
                }
                return def.compactionCustomInstructionsBlock
            }()
            let compactionIdentifierPreservationMode: String = {
                if let value = payload["compactionIdentifierPreservationMode"] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return trimmed.isEmpty ? def.compactionIdentifierPreservationMode : trimmed
                }
                return def.compactionIdentifierPreservationMode
            }()
            let compactionIdentifierPreservationCustomInstructions: String = {
                if let value = payload["compactionIdentifierPreservationCustomInstructions"] as? String {
                    return value
                }
                return def.compactionIdentifierPreservationCustomInstructions
            }()
            let compactionSummarizerContextLimitTokens: Int = {
                if let value = payload["compactionSummarizerContextLimitTokens"] as? Int {
                    return Swift.min(8_388_608, Swift.max(1024, value))
                }
                return def.compactionSummarizerContextLimitTokens
            }()
            let proactiveSafetyBufferTokens: Int = {
                if let value = payload["proactiveSafetyBufferTokens"] as? Int {
                    return Swift.min(8_388_608, Swift.max(0, value))
                }
                return def.proactiveSafetyBufferTokens
            }()
            let proactiveOutputReserveTokens: Int = {
                if let value = payload["proactiveOutputReserveTokens"] as? Int {
                    return Swift.min(8_388_608, Swift.max(0, value))
                }
                return def.proactiveOutputReserveTokens
            }()
            let reactiveTriggerEnabled = (payload["reactiveTriggerEnabled"] as? Bool) ?? def.reactiveTriggerEnabled
            let reactiveErrorPatterns: [String] = {
                if let arr = payload["reactiveErrorPatterns"] as? [String] {
                    let cleaned = arr
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    return cleaned
                }
                return def.reactiveErrorPatterns
            }()
            let oversizeRetryMaxAttempts: Int = {
                if let value = payload["oversizeRetryMaxAttempts"] as? Int {
                    return Swift.min(20, Swift.max(1, value))
                }
                return def.oversizeRetryMaxAttempts
            }()
            let oversizeRetryDropFraction: Double = {
                if let value = payload["oversizeRetryDropFraction"] as? Double {
                    return Swift.min(0.95, Swift.max(0, value))
                }
                if let value = payload["oversizeRetryDropFraction"] as? Int {
                    return Swift.min(0.95, Swift.max(0, Double(value)))
                }
                return def.oversizeRetryDropFraction
            }()
            let oversizeRetryMarker: String = {
                if let value = payload["oversizeRetryMarker"] as? String, !value.isEmpty {
                    return value
                }
                return def.oversizeRetryMarker
            }()
            let manualToolEnabled = (payload["manualToolEnabled"] as? Bool) ?? def.manualToolEnabled
            let manualToolMinUtilization: Double = {
                if let value = payload["manualToolMinUtilization"] as? Double {
                    return Swift.min(1, Swift.max(0, value))
                }
                if let value = payload["manualToolMinUtilization"] as? Int {
                    return Swift.min(1, Swift.max(0, Double(value)))
                }
                return def.manualToolMinUtilization
            }()
            let manualSlashEnabled = (payload["manualSlashEnabled"] as? Bool) ?? def.manualSlashEnabled
            let manualRESTEnabled = (payload["manualRESTEnabled"] as? Bool) ?? def.manualRESTEnabled
            let defaultSummarizationStrategy: String = {
                if let value = payload["defaultSummarizationStrategy"] as? String, !value.isEmpty {
                    return value
                }
                return def.defaultSummarizationStrategy
            }()
            let focusedCompactionQuery: String = {
                if let value = payload["focusedCompactionQuery"] as? String {
                    return value
                }
                return def.focusedCompactionQuery
            }()
            let cacheAwarePruningEnabled =
                (payload["cacheAwarePruningEnabled"] as? Bool) ?? def.cacheAwarePruningEnabled
            let cacheStablePrefixMessageCount: Int = {
                if let value = payload["cacheStablePrefixMessageCount"] as? Int {
                    return Swift.min(200, Swift.max(0, value))
                }
                return def.cacheStablePrefixMessageCount
            }()
            let cachePruningTTLSeconds: Double? = {
                if payload["cachePruningTTLSeconds"] is NSNull { return nil }
                if let value = payload["cachePruningTTLSeconds"] as? Double {
                    return value > 0 ? Swift.min(2_592_000, value) : nil
                }
                if let value = payload["cachePruningTTLSeconds"] as? Int {
                    return value > 0 ? Swift.min(2_592_000, Double(value)) : nil
                }
                return def.cachePruningTTLSeconds
            }()
            let contextPruningMode: String? = {
                if payload["contextPruningMode"] is NSNull { return nil }
                if let value = payload["contextPruningMode"] as? String, !value.isEmpty {
                    return value
                }
                return def.contextPruningMode
            }()
            let contextPruningKeepRecentToolResults: Int = {
                if let value = payload["contextPruningKeepRecentToolResults"] as? Int {
                    return Swift.min(200, Swift.max(0, value))
                }
                if let value = payload["context_pruning_keep_recent_tool_results"] as? Int {
                    return Swift.min(200, Swift.max(0, value))
                }
                return def.contextPruningKeepRecentToolResults
            }()
            let contextPruningTargetTools: [String]? = {
                if payload["contextPruningTargetTools"] is NSNull { return nil }
                if let value = payload["contextPruningTargetTools"] as? [String] {
                    return value.isEmpty ? nil : value
                }
                if let value = payload["context_pruning_target_tools"] as? [String] {
                    return value.isEmpty ? nil : value
                }
                return def.contextPruningTargetTools
            }()
            let cacheExpiryInferenceThresholdSeconds: Double? = {
                if payload["cacheExpiryInferenceThresholdSeconds"] is NSNull { return nil }
                if let value = payload["cacheExpiryInferenceThresholdSeconds"] as? Double {
                    return value > 0 ? Swift.min(2_592_000, value) : nil
                }
                if let value = payload["cacheExpiryInferenceThresholdSeconds"] as? Int {
                    return value > 0 ? Swift.min(2_592_000, Double(value)) : nil
                }
                return def.cacheExpiryInferenceThresholdSeconds
            }()
            let deterministicToolResultPruningEnabled =
                (payload["deterministicToolResultPruningEnabled"] as? Bool)
                ?? def.deterministicToolResultPruningEnabled
            let deterministicAttachmentDocumentHygieneEnabled =
                (payload["deterministicAttachmentDocumentHygieneEnabled"] as? Bool)
                ?? def.deterministicAttachmentDocumentHygieneEnabled
            let deterministicMaxImagesPerMessage: Int = {
                if let value = payload["deterministicMaxImagesPerMessage"] as? Int {
                    return Swift.min(20, Swift.max(0, value))
                }
                return def.deterministicMaxImagesPerMessage
            }()
            let deterministicDocumentCharacterThreshold: Int = {
                if let value = payload["deterministicDocumentCharacterThreshold"] as? Int {
                    return Swift.min(2_000_000, Swift.max(0, value))
                }
                return def.deterministicDocumentCharacterThreshold
            }()
            let deterministicDocumentPlaceholder: String = {
                if let value = payload["deterministicDocumentPlaceholder"] as? String {
                    return value
                }
                return def.deterministicDocumentPlaceholder
            }()
            let deterministicDocumentPreviewMaxBytes: Int = {
                if let value = payload["deterministicDocumentPreviewMaxBytes"] as? Int {
                    return Swift.min(1_000_000, Swift.max(0, value))
                }
                return def.deterministicDocumentPreviewMaxBytes
            }()
            let deterministicImagePlaceholder: String = {
                if let value = payload["deterministicImagePlaceholder"] as? String {
                    return value
                }
                return def.deterministicImagePlaceholder
            }()
            let preCompactionMemoryFlushEnabled =
                (payload["preCompactionMemoryFlushEnabled"] as? Bool)
                ?? def.preCompactionMemoryFlushEnabled
            let preCompactionMemoryFlushMaxEntries: Int = {
                if let value = payload["preCompactionMemoryFlushMaxEntries"] as? Int {
                    return Swift.min(500, Swift.max(1, value))
                }
                return def.preCompactionMemoryFlushMaxEntries
            }()
            let softThresholdTokens: Int = {
                if let value = payload["softThresholdTokens"] as? Int {
                    let upper = Swift.min(100_000, Swift.max(0, proactiveSafetyBufferTokens * 2))
                    return Swift.min(upper, Swift.max(0, value))
                }
                return def.softThresholdTokens
            }()
            let optionalCompactionProviderSlot: String? = {
                if payload["optionalCompactionProviderSlot"] is NSNull { return nil }
                if let value = payload["optionalCompactionProviderSlot"] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return def.optionalCompactionProviderSlot
            }()
            let optionalCompactionProviderFallbackToOllama =
                (payload["optionalCompactionProviderFallbackToOllama"] as? Bool)
                ?? def.optionalCompactionProviderFallbackToOllama
            let compactionSummarizerMaxOutputTokens: Int = {
                let raw = (payload["compactionSummarizerMaxOutputTokens"] as? Int)
                    ?? def.compactionSummarizerMaxOutputTokens
                // No fixed-budget clamp here: `resolvedSummarizerMaxOutputTokens` owns the
                // proportional-aware ceiling and the 20k reserve floor.
                return Swift.max(1, raw)
            }()
            return ContextCompactionConfiguration(
                enabled: enabled,
                ollamaServerURL: ollamaURL,
                model: model,
                fallbackContextLimitTokens: fallbackContextLimitTokens,
                charactersPerToken: charactersPerToken,
                maxCompactedMiddleMessages: maxCompactedMiddleMessages,
                middleMinCharactersForCompactionLLM: middleMinCharactersForCompactionLLM,
                compactionLLMCooldownSeconds: compactionLLMCooldownSeconds,
                compactionToolResultPruneNames: compactionToolResultPruneNames,
                maxRecentToolResults: maxRecentToolResults,
                maxRecentPerNameToolResults: maxRecentPerNameToolResults,
                toolResultPruneReplacementMode: toolResultPruneReplacementMode,
                compactionSummaryBudgetTokens: compactionSummaryBudgetTokens,
                compactionCustomInstructionsBlock: compactionCustomInstructionsBlock,
                compactionIdentifierPreservationMode: compactionIdentifierPreservationMode,
                compactionIdentifierPreservationCustomInstructions: compactionIdentifierPreservationCustomInstructions,
                compactionSummarizerContextLimitTokens: compactionSummarizerContextLimitTokens,
                proactiveSafetyBufferTokens: proactiveSafetyBufferTokens,
                proactiveOutputReserveTokens: proactiveOutputReserveTokens,
                reactiveTriggerEnabled: reactiveTriggerEnabled,
                reactiveErrorPatterns: reactiveErrorPatterns,
                oversizeRetryMaxAttempts: oversizeRetryMaxAttempts,
                oversizeRetryDropFraction: oversizeRetryDropFraction,
                oversizeRetryMarker: oversizeRetryMarker,
                manualToolEnabled: manualToolEnabled,
                manualToolMinUtilization: manualToolMinUtilization,
                manualSlashEnabled: manualSlashEnabled,
                manualRESTEnabled: manualRESTEnabled,
                defaultSummarizationStrategy: defaultSummarizationStrategy,
                focusedCompactionQuery: focusedCompactionQuery,
                cacheAwarePruningEnabled: cacheAwarePruningEnabled,
                cacheStablePrefixMessageCount: cacheStablePrefixMessageCount,
                cachePruningTTLSeconds: cachePruningTTLSeconds,
                contextPruningMode: contextPruningMode,
                contextPruningKeepRecentToolResults: contextPruningKeepRecentToolResults,
                contextPruningTargetTools: contextPruningTargetTools,
                cacheExpiryInferenceThresholdSeconds: cacheExpiryInferenceThresholdSeconds,
                deterministicToolResultPruningEnabled: deterministicToolResultPruningEnabled,
                deterministicAttachmentDocumentHygieneEnabled: deterministicAttachmentDocumentHygieneEnabled,
                deterministicMaxImagesPerMessage: deterministicMaxImagesPerMessage,
                deterministicDocumentCharacterThreshold: deterministicDocumentCharacterThreshold,
                deterministicDocumentPlaceholder: deterministicDocumentPlaceholder,
                deterministicDocumentPreviewMaxBytes: deterministicDocumentPreviewMaxBytes,
                deterministicImagePlaceholder: deterministicImagePlaceholder,
                preCompactionMemoryFlushEnabled: preCompactionMemoryFlushEnabled,
                preCompactionMemoryFlushMaxEntries: preCompactionMemoryFlushMaxEntries,
                softThresholdTokens: softThresholdTokens,
                optionalCompactionProviderSlot: optionalCompactionProviderSlot,
                optionalCompactionProviderFallbackToOllama: optionalCompactionProviderFallbackToOllama,
                headMinMessageCount: (payload["headMinMessageCount"] as? Int) ?? def.headMinMessageCount,
                tailMinMessageCount: (payload["tailMinMessageCount"] as? Int) ?? def.tailMinMessageCount,
                tailTokenBudgetFraction: (payload["tailTokenBudgetFraction"] as? Double) ?? def.tailTokenBudgetFraction,
                compactionSummarizerMaxOutputTokens: compactionSummarizerMaxOutputTokens,
                compactionSummaryBudgetProportionalEnabled: (payload["compactionSummaryBudgetProportionalEnabled"] as? Bool)
                    ?? def.compactionSummaryBudgetProportionalEnabled,
                sessionMemorySwapBeforeCompactionEnabled: (payload["sessionMemorySwapBeforeCompactionEnabled"] as? Bool)
                    ?? def.sessionMemorySwapBeforeCompactionEnabled,
                compactionReinjectionEnabled: (payload["compactionReinjectionEnabled"] as? Bool)
                    ?? def.compactionReinjectionEnabled,
                reinjectionRecentFileCount: (payload["reinjectionRecentFileCount"] as? Int)
                    ?? (payload["reinjection_recent_file_count"] as? Int)
                    ?? def.reinjectionRecentFileCount,
                reinjectionPerFileTokenBudget: (payload["reinjectionPerFileTokenBudget"] as? Int)
                    ?? (payload["reinjection_per_file_token_budget"] as? Int)
                    ?? def.reinjectionPerFileTokenBudget,
                reinjectionTotalFileTokenBudget: (payload["reinjectionTotalFileTokenBudget"] as? Int)
                    ?? (payload["reinjection_total_file_token_budget"] as? Int)
                    ?? def.reinjectionTotalFileTokenBudget,
                reinjectionPerSkillTokenBudget: (payload["reinjectionPerSkillTokenBudget"] as? Int)
                    ?? (payload["reinjection_per_skill_token_budget"] as? Int)
                    ?? def.reinjectionPerSkillTokenBudget,
                reinjectionTotalSkillTokenBudget: (payload["reinjectionTotalSkillTokenBudget"] as? Int)
                    ?? (payload["reinjection_total_skill_token_budget"] as? Int)
                    ?? def.reinjectionTotalSkillTokenBudget,
                reinjectFileContentEnabled: (payload["reinjectFileContentEnabled"] as? Bool)
                    ?? (payload["reinject_file_content_enabled"] as? Bool)
                    ?? def.reinjectFileContentEnabled,
                reinjectionInstructionSectionsEnabled: (payload["reinjectionInstructionSectionsEnabled"] as? Bool)
                    ?? (payload["reinjection_instruction_sections_enabled"] as? Bool)
                    ?? def.reinjectionInstructionSectionsEnabled,
                reinjectionInstructionSectionNames: (payload["reinjectionInstructionSectionNames"] as? [String])
                    ?? (payload["reinjection_instruction_section_names"] as? [String])
                    ?? def.reinjectionInstructionSectionNames,
                reinjectionInstructionSectionMaxCharacters: (payload["reinjectionInstructionSectionMaxCharacters"] as? Int)
                    ?? (payload["reinjection_instruction_section_max_characters"] as? Int)
                    ?? def.reinjectionInstructionSectionMaxCharacters,
                compactionCircuitBreakerMaxFailures: (payload["compactionCircuitBreakerMaxFailures"] as? Int)
                    ?? def.compactionCircuitBreakerMaxFailures,
                compactionMinPromptTokenSavingsFraction: (payload["compactionMinPromptTokenSavingsFraction"] as? Double)
                    ?? def.compactionMinPromptTokenSavingsFraction,
                useSessionTreeProjection: (payload["useSessionTreeProjection"] as? Bool) ?? def.useSessionTreeProjection
            )
        }
        func slashCommands(_ key: String, default def: SlashCommandConfiguration) -> SlashCommandConfiguration {
            guard let payload = block[key] as? [String: Any] else {
                return def
            }
            let enabled = (payload["enabled"] as? Bool) ?? def.enabled
            let allowUnknownPassthrough = (payload["allowUnknownPassthrough"] as? Bool) ?? def.allowUnknownPassthrough
            let compactEnabled = (payload["compactEnabled"] as? Bool) ?? def.compactEnabled
            let skillSlashEnabled = (payload["skillSlashEnabled"] as? Bool) ?? def.skillSlashEnabled
            let directivesEnabled = (payload["directivesEnabled"] as? Bool) ?? def.directivesEnabled
            let inlineShortcutsEnabled = (payload["inlineShortcutsEnabled"] as? Bool) ?? def.inlineShortcutsEnabled
            let ownerOnlyDirectiveNames: [String] = {
                if let rows = payload["ownerOnlyDirectiveNames"] as? [String] {
                    return rows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                }
                return def.ownerOnlyDirectiveNames
            }()
            let toolDispatchCommands: [SlashCommandConfiguration.ToolDispatchCommand] = {
                guard let rows = payload["toolDispatchCommands"] as? [[String: Any]] else {
                    return def.toolDispatchCommands
                }
                return rows.compactMap { row in
                    guard let rawCommand = row["command"] as? String,
                          let rawToolName = row["toolName"] as? String
                    else {
                        return nil
                    }
                    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty, !toolName.isEmpty else {
                        return nil
                    }
                    let argMode: SlashToolDispatchArgMode = {
                        if let raw = row["argMode"] as? String,
                           let parsed = SlashToolDispatchArgMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                            return parsed
                        }
                        return .raw
                    }()
                    let description = (row["description"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Dispatch /\(command) to tool \(toolName)."
                    let aliases = (row["aliases"] as? [String] ?? [])
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                    let bypassTier: SlashCommandBypassTier = {
                        if let raw = row["bypassTier"] as? String,
                           let parsed = SlashCommandBypassTier(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            return parsed
                        }
                        return .queued
                    }()
                    return SlashCommandConfiguration.ToolDispatchCommand(
                        command: command,
                        toolName: toolName,
                        argMode: argMode,
                        description: description.isEmpty ? "Dispatch /\(command) to tool \(toolName)." : description,
                        argumentHint: row["argumentHint"] as? String,
                        hiddenKeywords: (row["hiddenKeywords"] as? String) ?? "",
                        aliases: aliases,
                        ownerOnly: (row["ownerOnly"] as? Bool) ?? false,
                        bypassTier: bypassTier,
                        enabled: (row["enabled"] as? Bool) ?? true
                    )
                }
            }()
            let staticSkillNamesExcludedFromSkillColon: [String] = {
                if let arr = payload["staticSkillNamesExcludedFromSkillColon"] as? [String] {
                    return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                }
                return def.staticSkillNamesExcludedFromSkillColon
            }()
            return SlashCommandConfiguration(
                enabled: enabled,
                allowUnknownPassthrough: allowUnknownPassthrough,
                compactEnabled: compactEnabled,
                skillSlashEnabled: skillSlashEnabled,
                directivesEnabled: directivesEnabled,
                inlineShortcutsEnabled: inlineShortcutsEnabled,
                ownerOnlyDirectiveNames: ownerOnlyDirectiveNames,
                toolDispatchCommands: toolDispatchCommands,
                staticSkillNamesExcludedFromSkillColon: staticSkillNamesExcludedFromSkillColon
            )
        }
        func toolResultFormatting(_ key: String, default def: ToolResultFormattingConfiguration) -> ToolResultFormattingConfiguration {
            guard let payload = block[key] as? [String: Any] else {
                return def
            }
            let enabled = (payload["enabled"] as? Bool) ?? def.enabled
            let runtimeMaxCharacters: Int = {
                if let value = payload["runtimeMaxCharacters"] as? Int {
                    return Swift.min(2_000_000, Swift.max(0, value))
                }
                return def.runtimeMaxCharacters
            }()
            let persistenceMaxCharacters: Int = {
                if let value = payload["persistenceMaxCharacters"] as? Int {
                    return Swift.min(2_000_000, Swift.max(0, value))
                }
                return def.persistenceMaxCharacters
            }()
            let compactionMaxCharacters: Int = {
                if let value = payload["compactionMaxCharacters"] as? Int {
                    return Swift.min(2_000_000, Swift.max(0, value))
                }
                return def.compactionMaxCharacters
            }()
            let runtimeMaxBytes: Int = {
                if let value = payload["runtimeMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.runtimeMaxBytes
            }()
            let persistenceMaxBytes: Int = {
                if let value = payload["persistenceMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.persistenceMaxBytes
            }()
            let compactionMaxBytes: Int = {
                if let value = payload["compactionMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.compactionMaxBytes
            }()
            let runtimeMetadataMaxBytes: Int = {
                if let value = payload["runtimeMetadataMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.runtimeMetadataMaxBytes
            }()
            let persistenceMetadataMaxBytes: Int = {
                if let value = payload["persistenceMetadataMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.persistenceMetadataMaxBytes
            }()
            let compactionMetadataMaxBytes: Int = {
                if let value = payload["compactionMetadataMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.compactionMetadataMaxBytes
            }()
            let maxLines: Int = {
                if let value = payload["maxLines"] as? Int {
                    return Swift.min(20_000, Swift.max(0, value))
                }
                return def.maxLines
            }()
            let sanitizeInlineImagePayloads =
                (payload["sanitizeInlineImagePayloads"] as? Bool)
                ?? def.sanitizeInlineImagePayloads
            let maxInlineImagePixelDimension: Int = {
                if let value = payload["maxInlineImagePixelDimension"] as? Int {
                    return Swift.min(16_384, Swift.max(0, value))
                }
                return def.maxInlineImagePixelDimension
            }()
            let maxInlineImageBytes: Int = {
                if let value = payload["maxInlineImageBytes"] as? Int {
                    return Swift.min(32_000_000, Swift.max(0, value))
                }
                return def.maxInlineImageBytes
            }()
            let imagePayloadPlaceholder: String = {
                if let value = payload["imagePayloadPlaceholder"] as? String {
                    return value
                }
                return def.imagePayloadPlaceholder
            }()
            let compactionImagePayloadPlaceholder: String = {
                if let value = payload["compactionImagePayloadPlaceholder"] as? String {
                    return value
                }
                return def.compactionImagePayloadPlaceholder
            }()
            let metadataPlaceholder: String = {
                if let value = payload["metadataPlaceholder"] as? String {
                    return value
                }
                return def.metadataPlaceholder
            }()
            let compactionMetadataPlaceholder: String = {
                if let value = payload["compactionMetadataPlaceholder"] as? String {
                    return value
                }
                return def.compactionMetadataPlaceholder
            }()
            let truncationMarker: String = {
                if let value = payload["truncationMarker"] as? String {
                    return value
                }
                return def.truncationMarker
            }()
            let compactionTruncationMarker: String = {
                if let value = payload["compactionTruncationMarker"] as? String {
                    return value
                }
                return def.compactionTruncationMarker
            }()
            let spillEnabled = (payload["spillEnabled"] as? Bool) ?? def.spillEnabled
            let spillPreviewMaxBytes: Int = {
                if let value = payload["spillPreviewMaxBytes"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.spillPreviewMaxBytes
            }()
            let defaultMaxResultSizeBeforeSpill: Int = {
                if let value = payload["defaultMaxResultSizeBeforeSpill"] as? Int {
                    return Swift.min(8_000_000, Swift.max(0, value))
                }
                return def.defaultMaxResultSizeBeforeSpill
            }()
            return ToolResultFormattingConfiguration(
                enabled: enabled,
                spillEnabled: spillEnabled,
                spillPreviewMaxBytes: spillPreviewMaxBytes,
                defaultMaxResultSizeBeforeSpill: defaultMaxResultSizeBeforeSpill,
                runtimeMaxCharacters: runtimeMaxCharacters,
                persistenceMaxCharacters: persistenceMaxCharacters,
                compactionMaxCharacters: compactionMaxCharacters,
                runtimeMaxBytes: runtimeMaxBytes,
                persistenceMaxBytes: persistenceMaxBytes,
                compactionMaxBytes: compactionMaxBytes,
                runtimeMetadataMaxBytes: runtimeMetadataMaxBytes,
                persistenceMetadataMaxBytes: persistenceMetadataMaxBytes,
                compactionMetadataMaxBytes: compactionMetadataMaxBytes,
                maxLines: maxLines,
                sanitizeInlineImagePayloads: sanitizeInlineImagePayloads,
                maxInlineImagePixelDimension: maxInlineImagePixelDimension,
                maxInlineImageBytes: maxInlineImageBytes,
                imagePayloadPlaceholder: imagePayloadPlaceholder,
                compactionImagePayloadPlaceholder: compactionImagePayloadPlaceholder,
                metadataPlaceholder: metadataPlaceholder,
                compactionMetadataPlaceholder: compactionMetadataPlaceholder,
                truncationMarker: truncationMarker,
                compactionTruncationMarker: compactionTruncationMarker
            )
        }

        let baseline = TransformHookToggles(
            enableContextTransform: bool("enableContextTransform", default: true),
            enableToolResultTransform: bool("enableToolResultTransform", default: true),
            enableTurnSummaryTransform: bool("enableTurnSummaryTransform", default: true)
        )

        func togglesForModeKey(_ modeKey: String) -> TransformHookToggles {
            guard let modeBlock = block[modeKey] as? [String: Any] else {
                return baseline
            }
            func modeBool(_ key: String) -> Bool {
                if let v = modeBlock[key] as? Bool { return v }
                switch key {
                case "enableContextTransform": return baseline.enableContextTransform
                case "enableToolResultTransform": return baseline.enableToolResultTransform
                case "enableTurnSummaryTransform": return baseline.enableTurnSummaryTransform
                default: return true
                }
            }
            return TransformHookToggles(
                enableContextTransform: modeBool("enableContextTransform"),
                enableToolResultTransform: modeBool("enableToolResultTransform"),
                enableTurnSummaryTransform: modeBool("enableTurnSummaryTransform")
            )
        }

        return ConversationTransformConfiguration(
            chat: togglesForModeKey("chat"),
            plan: togglesForModeKey("plan"),
            agent: togglesForModeKey("agent"),
            transformTimeoutSeconds: timeout("transformTimeoutSeconds", default: 1800),
            contextCompaction: contextCompaction("contextCompaction", default: .default),
            slashCommands: slashCommands("slashCommands", default: .default),
            toolResultFormatting: toolResultFormatting("toolResultFormatting", default: .default)
        )
    }
}
