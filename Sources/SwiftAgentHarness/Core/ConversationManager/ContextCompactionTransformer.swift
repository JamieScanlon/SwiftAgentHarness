import CryptoKit
import Foundation
import Logging
import SwiftAgentKit

protocol ContextCompactionSummarizing: Sendable {
    /// Legacy 3-argument signature retained as the protocol's only required entry point so existing
    /// stubs/conformers compile unchanged. The transformer always calls
    /// ``summarizeMiddle(messages:maxMessages:debugOutputPath:customInstructionsOverride:identifierPreservationPolicy:)``;
    /// implementations that need to honour the override (e.g. ``OllamaContextCompactionSummarizer``)
    /// override the extended method directly.
    func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message]

    /// Summarize a middle slice with an optional one-shot replacement for the configured
    /// `compactionCustomInstructionsBlock` and optional identifier-preservation policy. Default
    /// implementation ignores these extended inputs and
    /// delegates to the 3-argument method.
    func summarizeMiddle(
        messages: [Message],
        maxMessages: Int,
        debugOutputPath: String?,
        customInstructionsOverride: String?,
        identifierPreservationPolicy: ContextCompactionIdentifierPreservationPolicy?,
        previousSummaryText: String?,
        summaryBudgetTokens: Int,
        maxOutputTokens: Int
    ) async throws -> [Message]
}

extension ContextCompactionSummarizing {
    func summarizeMiddle(
        messages: [Message],
        maxMessages: Int,
        debugOutputPath: String?,
        customInstructionsOverride _: String?,
        identifierPreservationPolicy _: ContextCompactionIdentifierPreservationPolicy?,
        previousSummaryText _: String?,
        summaryBudgetTokens _: Int,
        maxOutputTokens _: Int
    ) async throws -> [Message] {
        try await summarizeMiddle(
            messages: messages,
            maxMessages: maxMessages,
            debugOutputPath: debugOutputPath
        )
    }
}

protocol ToolResultSummarizing: Sendable {
    func summarize(
        toolCall: ToolCall,
        rawResult: ToolResult,
        conversation: ConversationTransformMetadata
    ) async throws -> String
}

struct TurnSummaryDecision: Sendable {
    let succeeded: Bool
    let summary: String
}

protocol TurnSummarizing: Sendable {
    func summarizeTurn(
        turnMessages: [Message],
        conversation: ConversationTransformMetadata
    ) async throws -> TurnSummaryDecision
}

struct ContextCompactionProviderBundle: Sendable {
    let summarizer: any ContextCompactionSummarizing
    let toolResultSummarizer: any ToolResultSummarizing
    let turnSummarizer: any TurnSummarizing
}

struct ContextCompactionLLMScheduling: Sendable {
    let scheduler: any ModelCallScheduling
    let modelID: UUID

    static func modelID(model: String, ollamaServerURL: URL) -> UUID {
        let modelToken = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endpointToken = ollamaServerURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "context-compaction|\(endpointToken)|\(modelToken)"
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        let byte0 = digest[0]
        let byte1 = digest[1]
        let byte2 = digest[2]
        let byte3 = digest[3]
        let byte4 = digest[4]
        let byte5 = digest[5]
        let byte6 = (digest[6] & 0x0F) | 0x50
        let byte7 = digest[7]
        let byte8 = (digest[8] & 0x3F) | 0x80
        let byte9 = digest[9]
        let byte10 = digest[10]
        let byte11 = digest[11]
        let byte12 = digest[12]
        let byte13 = digest[13]
        let byte14 = digest[14]
        let byte15 = digest[15]
        return UUID(uuid: (byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7, byte8, byte9, byte10, byte11, byte12, byte13, byte14, byte15))
    }
}

func wrapCompactionLLMForScheduling(
    _ base: any LLMProtocol,
    scheduling: ContextCompactionLLMScheduling?
) -> any LLMProtocol {
    guard let scheduling else { return base }
    return SchedulingLLM(
        baseLLM: base,
        scheduler: scheduling.scheduler,
        modelID: scheduling.modelID,
        priority: .background
    )
}

protocol ContextCompactionProviderFactoring: Sendable {
    func makeProvider(
        config: ContextCompactionConfiguration,
        logger: Logger?,
        scheduling: ContextCompactionLLMScheduling?
    ) -> ContextCompactionProviderBundle?
}

enum ContextCompactionProviderSlot: String {
    case ollama
    case none
}

struct DefaultContextCompactionProviderFactory: ContextCompactionProviderFactoring {
    func makeProvider(
        config: ContextCompactionConfiguration,
        logger: Logger?,
        scheduling: ContextCompactionLLMScheduling?
    ) -> ContextCompactionProviderBundle? {
        let slot = ContextCompactionProviderSlot(
            rawValue: config.optionalCompactionProviderSlot ?? ContextCompactionProviderSlot.ollama.rawValue
        ) ?? .ollama
        switch slot {
        case .ollama:
            return nil
        case .none:
            let unavailable = ProviderUnavailableSummarizer(slot: slot.rawValue)
            let unavailableTool = ProviderUnavailableToolResultSummarizer(slot: slot.rawValue)
            let unavailableTurn = ProviderUnavailableTurnSummarizer(slot: slot.rawValue)
            guard config.optionalCompactionProviderFallbackToOllama else {
                return ContextCompactionProviderBundle(
                    summarizer: unavailable,
                    toolResultSummarizer: unavailableTool,
                    turnSummarizer: unavailableTurn
                )
            }
            return ContextCompactionProviderBundle(
                summarizer: FallbackContextCompactionSummarizer(
                    primary: unavailable,
                    fallback: OllamaContextCompactionSummarizer(config: config, logger: logger, scheduling: scheduling),
                    logger: logger
                ),
                toolResultSummarizer: FallbackToolResultSummarizer(
                    primary: unavailableTool,
                    fallback: OllamaToolResultSummarizer(config: config, logger: logger, scheduling: scheduling),
                    logger: logger
                ),
                turnSummarizer: FallbackTurnSummarizer(
                    primary: unavailableTurn,
                    fallback: OllamaTurnSummarizer(config: config, logger: logger, scheduling: scheduling),
                    logger: logger
                )
            )
        }
    }
}

struct ProviderUnavailableError: Error, Sendable {
    let slot: String
}

struct ProviderUnavailableSummarizer: ContextCompactionSummarizing {
    let slot: String

    func summarizeMiddle(messages _: [Message], maxMessages _: Int, debugOutputPath _: String?) async throws -> [Message] {
        throw ProviderUnavailableError(slot: slot)
    }
}

struct ProviderUnavailableToolResultSummarizer: ToolResultSummarizing {
    let slot: String

    func summarize(
        toolCall _: ToolCall,
        rawResult _: ToolResult,
        conversation _: ConversationTransformMetadata
    ) async throws -> String {
        throw ProviderUnavailableError(slot: slot)
    }
}

struct ProviderUnavailableTurnSummarizer: TurnSummarizing {
    let slot: String

    func summarizeTurn(
        turnMessages _: [Message],
        conversation _: ConversationTransformMetadata
    ) async throws -> TurnSummaryDecision {
        throw ProviderUnavailableError(slot: slot)
    }
}

struct FallbackContextCompactionSummarizer: ContextCompactionSummarizing {
    let primary: any ContextCompactionSummarizing
    let fallback: any ContextCompactionSummarizing
    let logger: Logger?

    func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
        try await summarizeMiddle(
            messages: messages,
            maxMessages: maxMessages,
            debugOutputPath: debugOutputPath,
            customInstructionsOverride: nil,
            identifierPreservationPolicy: nil,
            previousSummaryText: nil,
            summaryBudgetTokens: 2_000,
            maxOutputTokens: 20_000
        )
    }

    func summarizeMiddle(
        messages: [Message],
        maxMessages: Int,
        debugOutputPath: String?,
        customInstructionsOverride: String?,
        identifierPreservationPolicy: ContextCompactionIdentifierPreservationPolicy?,
        previousSummaryText: String?,
        summaryBudgetTokens: Int,
        maxOutputTokens: Int
    ) async throws -> [Message] {
        do {
            return try await primary.summarizeMiddle(
                messages: messages,
                maxMessages: maxMessages,
                debugOutputPath: debugOutputPath,
                customInstructionsOverride: customInstructionsOverride,
                identifierPreservationPolicy: identifierPreservationPolicy,
                previousSummaryText: previousSummaryText,
                summaryBudgetTokens: summaryBudgetTokens,
                maxOutputTokens: maxOutputTokens
            )
        } catch {
            logger?.warning("[ContextCompactionProvider] primary summarizeMiddle failed; falling back: \(error)")
            return try await fallback.summarizeMiddle(
                messages: messages,
                maxMessages: maxMessages,
                debugOutputPath: debugOutputPath,
                customInstructionsOverride: customInstructionsOverride,
                identifierPreservationPolicy: identifierPreservationPolicy,
                previousSummaryText: previousSummaryText,
                summaryBudgetTokens: summaryBudgetTokens,
                maxOutputTokens: maxOutputTokens
            )
        }
    }
}

struct FallbackToolResultSummarizer: ToolResultSummarizing {
    let primary: any ToolResultSummarizing
    let fallback: any ToolResultSummarizing
    let logger: Logger?

    func summarize(
        toolCall: ToolCall,
        rawResult: ToolResult,
        conversation: ConversationTransformMetadata
    ) async throws -> String {
        do {
            return try await primary.summarize(toolCall: toolCall, rawResult: rawResult, conversation: conversation)
        } catch {
            logger?.warning("[ContextCompactionProvider] primary tool-result summarizer failed; falling back: \(error)")
            return try await fallback.summarize(toolCall: toolCall, rawResult: rawResult, conversation: conversation)
        }
    }
}

struct FallbackTurnSummarizer: TurnSummarizing {
    let primary: any TurnSummarizing
    let fallback: any TurnSummarizing
    let logger: Logger?

    func summarizeTurn(
        turnMessages: [Message],
        conversation: ConversationTransformMetadata
    ) async throws -> TurnSummaryDecision {
        do {
            return try await primary.summarizeTurn(turnMessages: turnMessages, conversation: conversation)
        } catch {
            logger?.warning("[ContextCompactionProvider] primary turn summarizer failed; falling back: \(error)")
            return try await fallback.summarizeTurn(turnMessages: turnMessages, conversation: conversation)
        }
    }
}

struct ContextCompactionTransformer: ConversationTransforming {
    private let config: ContextCompactionConfiguration
    private let toolResultFormattingConfiguration: ToolResultFormattingConfiguration
    private let logger: Logger?
    private let summarizer: any ContextCompactionSummarizing
    private let toolResultSummarizer: any ToolResultSummarizing
    private let turnSummarizer: any TurnSummarizing
    private static let maxLoggedContentCharacters = 4_000

    // MARK: - Public diagnostic identifiers
    /// Emitted on a successful LLM-summarized compaction.
    static let summarizedDiagnostic = ContextCompactionCheckpointKind.summarizedDiagnostic
    /// Emitted when deterministic pruning alone brought total prompt tokens under the proactive threshold.
    static let prunedDiagnostic = ContextCompactionCheckpointKind.prunedDiagnostic
    /// Emitted when a summarized checkpoint is being reused and the conversation has no new raw tail to process.
    static let noopSummarizedNoNewTailDiagnostic = "context_compaction_noop_summarized_no_new_tail"

    static func makeProduction(
        config: ContextCompactionConfiguration,
        toolResultFormattingConfiguration: ToolResultFormattingConfiguration = .default,
        logger: Logger? = nil,
        providerFactory: (any ContextCompactionProviderFactoring)? = nil,
        scheduling: ContextCompactionLLMScheduling? = nil
    ) -> ContextCompactionTransformer {
        let resolvedFactory = providerFactory ?? DefaultContextCompactionProviderFactory()
        if let provider = resolvedFactory.makeProvider(config: config, logger: logger, scheduling: scheduling) {
            return ContextCompactionTransformer(
                config: config,
                toolResultFormattingConfiguration: toolResultFormattingConfiguration,
                logger: logger,
                summarizer: provider.summarizer,
                toolResultSummarizer: provider.toolResultSummarizer,
                turnSummarizer: provider.turnSummarizer
            )
        }
        return ContextCompactionTransformer(
            config: config,
            toolResultFormattingConfiguration: toolResultFormattingConfiguration,
            logger: logger
        )
    }

    init(
        config: ContextCompactionConfiguration,
        toolResultFormattingConfiguration: ToolResultFormattingConfiguration = .default,
        logger: Logger? = nil,
        summarizer: (any ContextCompactionSummarizing)? = nil,
        toolResultSummarizer: (any ToolResultSummarizing)? = nil,
        turnSummarizer: (any TurnSummarizing)? = nil,
        scheduling: ContextCompactionLLMScheduling? = nil
    ) {
        self.config = config
        self.toolResultFormattingConfiguration = toolResultFormattingConfiguration
        self.logger = logger
        self.summarizer = summarizer ?? OllamaContextCompactionSummarizer(config: config, logger: logger, scheduling: scheduling)
        self.toolResultSummarizer = toolResultSummarizer ?? OllamaToolResultSummarizer(config: config, logger: logger, scheduling: scheduling)
        self.turnSummarizer = turnSummarizer ?? OllamaTurnSummarizer(config: config, logger: logger, scheduling: scheduling)
    }

    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        let agentContextLimit = input.effectiveContextLimitTokens ?? config.fallbackContextLimitTokens
        let effectiveLimit = ContextCompactionPolicy.effectiveContextLimitForCompactionTrigger(
            agentContextLimitTokens: agentContextLimit,
            summarizerContextLimitTokens: config.compactionSummarizerContextLimitTokens
        )
        logger?.debug(
            "[ContextCompactionTransformer] transformContext input phase=\(input.phase) maxCompactedMiddleMessages=\(config.maxCompactedMiddleMessages) effectiveContextLimitTokens=\(effectiveLimit)\n\(Self.describeMessages(input.messages))"
        )
        guard config.enabled else {
            let output = passthroughOutput(
                messages: input.messages,
                diagnostics: "context_compaction_disabled"
            )
            logContextOutput(output)
            return output
        }
        guard case .initial = input.phase else {
            let output = passthroughOutput(
                messages: input.messages,
                diagnostics: "context_compaction_noop_non_initial"
            )
            logContextOutput(output)
            return output
        }
        guard !input.messages.isEmpty else {
            let output = passthroughOutput(
                messages: input.messages,
                diagnostics: "context_compaction_noop_empty"
            )
            logContextOutput(output)
            return output
        }

        let modelLimitForSplit = input.compactionModelContextLimitTokens ?? config.fallbackContextLimitTokens
        let splitBase = input.compactionSplitBaseMessages ?? input.messages
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            splitBase,
            config: config,
            modelContextLimitTokens: modelLimitForSplit
        )
        let injectedPrefix = input.compactionInjectedPrefixMessages ?? []
        let head = injectedPrefix + segments.head
        let tail = segments.tail
        let derivedMiddle = segments.middle
        let originalMiddleMessages = input.compactionRawMiddleMessages ?? derivedMiddle

        if originalMiddleMessages.isEmpty {
            var out = head
            out.append(contentsOf: tail)
            let output = ContextTransformOutput(
                messages: out,
                diagnostics: "context_compaction_noop_empty_middle",
                messageProvenance: out.map { m in
                    ContextTransformMessageProvenance(
                        transformedMessageID: m.id,
                        origin: .original,
                        sourceMessageIDs: [m.id]
                    )
                }
            )
            logContextOutput(output)
            return output
        }

        let effectiveMiddle = input.compactionEffectiveMiddle ?? originalMiddleMessages
        let middleBudget = max(0, config.maxCompactedMiddleMessages)
        if middleBudget == 0 {
            var minimal: [Message] = []
            minimal.append(contentsOf: head)
            minimal.append(contentsOf: tail)
            let output = ContextTransformOutput(
                messages: minimal,
                diagnostics: "context_compaction_minimal_preserve_only",
                messageProvenance: minimal.map { message in
                    ContextTransformMessageProvenance(
                        transformedMessageID: message.id,
                        origin: .original,
                        sourceMessageIDs: [message.id]
                    )
                }
            )
            logContextOutput(output)
            return output
        }

        let branchOutput: ContextTransformOutput
        do {
            switch input.compactionCheckpointKind {
            case .none:
                branchOutput = try await runFullFlow(
                    input: input,
                    head: head,
                    tail: tail,
                    middle: effectiveMiddle,
                    originalMiddleMessages: originalMiddleMessages,
                    middleBudget: middleBudget
                )
            case .pruned:
                branchOutput = try await runPrunedCheckpointFlow(
                    input: input,
                    head: head,
                    tail: tail,
                    effectiveMiddle: effectiveMiddle,
                    originalMiddleMessages: originalMiddleMessages,
                    middleBudget: middleBudget
                )
            case .summarized:
                branchOutput = try await runSummarizedCheckpointFlow(
                    input: input,
                    head: head,
                    tail: tail,
                    effectiveMiddle: effectiveMiddle,
                    originalMiddleMessages: originalMiddleMessages,
                    middleBudget: middleBudget
                )
            }
        } catch {
            logger?.debug("[ContextCompactionTransformer] transformContext summarizer error: \(String(describing: error))")
            let output = passthroughOutput(
                messages: input.messages,
                diagnostics: "context_compaction_failed"
            )
            logContextOutput(output)
            return output
        }
        logContextOutput(branchOutput)
        return branchOutput
    }

    // MARK: - Branches

    /// No checkpoint: run deterministic prune on the full middle, then either short-circuit (if
    /// pruning brought total prompt tokens under threshold) or LLM-summarize the pruned middle.
    private func runFullFlow(
        input: ContextTransformInput,
        head: [Message],
        tail: [Message],
        middle: [Message],
        originalMiddleMessages: [Message],
        middleBudget: Int
    ) async throws -> ContextTransformOutput {
        let deterministicMiddle = applyDeterministicPreCompactionHygiene(
            input: input,
            head: head,
            middle: middle,
            toolCallNameResolutionContext: head + middle,
            includeToolResultPruning: true
        )
        let middleAfterMemorySwap = applySessionMemorySwapIfNeeded(
            input: input,
            middle: deterministicMiddle,
            tail: tail
        )

        if prunedMiddleSatisfiesThreshold(input: input, head: head, prunedMiddle: middleAfterMemorySwap, tail: tail) {
            let diagnostic = input.compactionSessionMemoryNote != nil
                && config.sessionMemorySwapBeforeCompactionEnabled
                ? ContextCompactionCheckpointKind.memorySwapDiagnostic
                : Self.prunedDiagnostic
            return prunedShortCircuitOutput(
                head: head,
                prunedMiddle: middleAfterMemorySwap,
                tail: tail,
                diagnostics: diagnostic
            )
        }

        let summarizedMiddle = try await summarize(
            input: input,
            middleForSummarizerLLM: middleAfterMemorySwap,
            middleBudget: middleBudget
        )
        let reinjection = ContextCompactionReinjectionCollector.collectMessages(
            head: head,
            middle: middleAfterMemorySwap,
            tail: tail,
            config: config
        )
        return summarizedOutput(
            head: head,
            summarizedMiddle: summarizedMiddle,
            tail: tail,
            originalMiddleMessages: originalMiddleMessages,
            reinjectionMessages: reinjection
        )
    }

    /// Pruned-checkpoint reuse: skip the deterministic prune step (the prefix is already a pruned
    /// projection) and feed the effective middle straight to the LLM summarizer. The output is a
    /// `.summarized` checkpoint on the next persistence pass.
    private func runPrunedCheckpointFlow(
        input: ContextTransformInput,
        head: [Message],
        tail: [Message],
        effectiveMiddle: [Message],
        originalMiddleMessages: [Message],
        middleBudget: Int
    ) async throws -> ContextTransformOutput {
        let deterministicMiddle = applyDeterministicPreCompactionHygiene(
            input: input,
            head: head,
            middle: effectiveMiddle,
            toolCallNameResolutionContext: head,
            includeToolResultPruning: false
        )
        let summarizedMiddle = try await summarize(
            input: input,
            middleForSummarizerLLM: deterministicMiddle,
            middleBudget: middleBudget
        )
        let reinjection = ContextCompactionReinjectionCollector.collectMessages(
            head: head,
            middle: deterministicMiddle,
            tail: tail,
            config: config
        )
        return summarizedOutput(
            head: head,
            summarizedMiddle: summarizedMiddle,
            tail: tail,
            originalMiddleMessages: originalMiddleMessages,
            reinjectionMessages: reinjection
        )
    }

    /// Summarized-checkpoint reuse: process only the new raw tail beyond the checkpoint coverage.
    /// - Empty new tail: return head + effectiveMiddle + tail (passthrough-style noop).
    /// - Non-empty: prune the new tail with Part A semantics, then either short-circuit (output
    ///   prevSynth + prunedTail as `.pruned` per the open behavioural detail in the plan) or
    ///   LLM-summarize the pruned tail and concatenate prevSynth + new synth.
    private func runSummarizedCheckpointFlow(
        input: ContextTransformInput,
        head: [Message],
        tail: [Message],
        effectiveMiddle: [Message],
        originalMiddleMessages: [Message],
        middleBudget: Int
    ) async throws -> ContextTransformOutput {
        let prefixCount = min(
            max(0, input.compactionCheckpointPrefixCount ?? 0),
            effectiveMiddle.count
        )
        let strategyAdjusted = applyStrategyPolicy(
            input: input,
            head: head,
            middle: effectiveMiddle
        )
        let prevSynth = Array(strategyAdjusted.prefix(prefixCount))
        let newRawTail = Array(strategyAdjusted.dropFirst(prefixCount))
        if newRawTail.isEmpty {
            return summarizedNoNewTailOutput(head: head, prevSynth: prevSynth, tail: tail)
        }
        let deterministicNewTail = applyDeterministicPreCompactionHygiene(
            input: input,
            head: head,
            middle: newRawTail,
            toolCallNameResolutionContext: head + prevSynth + newRawTail,
            includeToolResultPruning: true
        )

        let composedMiddle = prevSynth + deterministicNewTail
        if prunedMiddleSatisfiesThreshold(input: input, head: head, prunedMiddle: composedMiddle, tail: tail) {
            // Per plan B.5: appended messages still carry tool-result content, so the kind is `.pruned`.
            return prunedShortCircuitOutput(head: head, prunedMiddle: composedMiddle, tail: tail)
        }

        let summarizedNewTail = try await summarize(
            input: input,
            middleForSummarizerLLM: deterministicNewTail,
            middleBudget: middleBudget
        )
        let mergedSynth = summarizedNewTail
        let reinjection = ContextCompactionReinjectionCollector.collectMessages(
            head: head,
            middle: composedMiddle,
            tail: tail,
            config: config
        )
        return summarizedOutput(
            head: head,
            summarizedMiddle: mergedSynth,
            tail: tail,
            originalMiddleMessages: originalMiddleMessages,
            reinjectionMessages: reinjection
        )
    }

    // MARK: - Output helpers

    /// Passthrough-shaped output for the "summarized checkpoint, no new tail" case. Preserves the
    /// existing synthesized prefix verbatim and stamps every message with `.original` provenance.
    private func summarizedNoNewTailOutput(
        head: [Message],
        prevSynth: [Message],
        tail: [Message]
    ) -> ContextTransformOutput {
        var messages: [Message] = []
        messages.append(contentsOf: head)
        messages.append(contentsOf: prevSynth)
        messages.append(contentsOf: tail)
        return ContextTransformOutput(
            messages: messages,
            diagnostics: Self.noopSummarizedNoNewTailDiagnostic,
            messageProvenance: messages.map { m in
                ContextTransformMessageProvenance(
                    transformedMessageID: m.id,
                    origin: .original,
                    sourceMessageIDs: [m.id]
                )
            }
        )
    }

    /// Short-circuit output (`context_compacted_pruned`). The middle is a pruned projection of
    /// the (possibly-merged) effective middle; IDs are unchanged from their sources so every
    /// message gets `.original` provenance.
    private func applySessionMemorySwapIfNeeded(
        input: ContextTransformInput,
        middle: [Message],
        tail: [Message]
    ) -> [Message] {
        guard config.sessionMemorySwapBeforeCompactionEnabled,
              let note = input.compactionSessionMemoryNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty
        else {
            return middle
        }
        return ContextCompactionSessionMemorySwap.swappedMiddle(note: note, middle: middle, tail: tail)
    }

    private func prunedShortCircuitOutput(
        head: [Message],
        prunedMiddle: [Message],
        tail: [Message],
        diagnostics: String = ContextCompactionTransformer.prunedDiagnostic
    ) -> ContextTransformOutput {
        var messages: [Message] = []
        messages.append(contentsOf: head)
        messages.append(contentsOf: prunedMiddle)
        messages.append(contentsOf: tail)
        return ContextTransformOutput(
            messages: messages,
            diagnostics: diagnostics,
            messageProvenance: messages.map { m in
                ContextTransformMessageProvenance(
                    transformedMessageID: m.id,
                    origin: .original,
                    sourceMessageIDs: [m.id]
                )
            }
        )
    }

    /// Standard summarize output (`context_compacted`). Synthesized middle messages get
    /// `.synthesized` provenance attributed to the original raw middle.
    private func summarizedOutput(
        head: [Message],
        summarizedMiddle: [Message],
        tail: [Message],
        originalMiddleMessages: [Message],
        reinjectionMessages: [Message] = []
    ) -> ContextTransformOutput {
        var compacted: [Message] = []
        var provenance: [ContextTransformMessageProvenance] = []
        compacted.append(contentsOf: head)
        for h in head {
            provenance.append(
                ContextTransformMessageProvenance(
                    transformedMessageID: h.id,
                    origin: .original,
                    sourceMessageIDs: [h.id]
                )
            )
        }
        var effectiveTail = tail
        var summaryMessages = summarizedMiddle
        if let summaryBody = summarizedMiddle.first?.content {
            let assembled = ContextCompactionSummaryMessageAssembler.assemble(
                summaryBody: summaryBody,
                tail: tail
            )
            summaryMessages = assembled.messages
            if assembled.mergedIntoTail {
                effectiveTail = tail
                summaryMessages = []
            }
        }
        compacted.append(contentsOf: summaryMessages)
        let middleSourceIDs = originalMiddleMessages.map(\.id)
        provenance.append(contentsOf: summaryMessages.map { message in
            ContextTransformMessageProvenance(
                transformedMessageID: message.id,
                origin: .synthesized,
                sourceMessageIDs: middleSourceIDs
            )
        })
        compacted.append(contentsOf: reinjectionMessages)
        provenance.append(contentsOf: reinjectionMessages.map { message in
            ContextTransformMessageProvenance(
                transformedMessageID: message.id,
                origin: .reinjected,
                sourceMessageIDs: middleSourceIDs
            )
        })
        compacted.append(contentsOf: effectiveTail)
        for t in effectiveTail {
            provenance.append(
                ContextTransformMessageProvenance(
                    transformedMessageID: t.id,
                    origin: .original,
                    sourceMessageIDs: [t.id]
                )
            )
        }
        return ContextTransformOutput(
            messages: compacted,
            diagnostics: Self.summarizedDiagnostic,
            messageProvenance: provenance
        )
    }

    /// LLM summarization step shared by all three branches. Honors `middleBudget` and the
    /// optional one-shot custom instructions override, and clamps the LLM response to the budget.
    private func summarize(
        input: ContextTransformInput,
        middleForSummarizerLLM: [Message],
        middleBudget: Int
    ) async throws -> [Message] {
        logger?.info(
            "[ContextCompactionTransformer] LLM call: summarizeMiddle (compaction) middleIn=\(middleForSummarizerLLM.count) maxOut=\(middleBudget) model=\(config.model)"
        )
        let tokensCompressed = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: middleForSummarizerLLM,
            charactersPerToken: config.charactersPerToken
        )
        let summaryBudget = ContextCompactionPolicy.resolvedSummaryBudgetTokens(
            tokensCompressed: tokensCompressed,
            config: config
        )
        let raw = try await summarizer.summarizeMiddle(
            messages: middleForSummarizerLLM,
            maxMessages: middleBudget,
            debugOutputPath: input.compactionSummarizerDebugOutputPath,
            customInstructionsOverride: input.compactionCustomInstructionsOverride,
            identifierPreservationPolicy: input.compactionIdentifierPreservationPolicy,
            previousSummaryText: input.compactionPreviousSummaryText,
            summaryBudgetTokens: summaryBudget,
            maxOutputTokens: config.resolvedSummarizerMaxOutputTokens
        )
        return Self.validateCompactedMiddleMessages(raw, maxMessages: middleBudget)
    }

    // MARK: - Threshold check

    /// `true` when total prompt tokens for `head + prunedMiddle + tail` are at or below the
    /// proactive threshold derived from the model context window. Falls back to estimation when
    /// `compactionLastPromptTokens` is `nil`. The estimate is recomputed from the post-prune
    /// payload, while a real `lastPromptTokens` is treated as a worst-case bound: pruning could
    /// only shrink the payload, so if the actual count was under threshold we trivially still are.
    private func prunedMiddleSatisfiesThreshold(
        input: ContextTransformInput,
        head: [Message],
        prunedMiddle: [Message],
        tail: [Message]
    ) -> Bool {
        let modelLimit = input.compactionModelContextLimitTokens ?? config.fallbackContextLimitTokens
        let threshold = ContextCompactionPolicy.proactiveThresholdTokens(
            modelContextLimitTokens: modelLimit,
            config: config
        )
        // Always estimate over the post-prune payload — the real `lastPromptTokens` reflects
        // PRE-prune content and would over-count.
        let combined = head + prunedMiddle + tail
        let estimated = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: combined,
            charactersPerToken: config.charactersPerToken
        )
        return estimated <= threshold
    }

    private func applyStrategyPolicy(
        input: ContextTransformInput,
        head: [Message],
        middle: [Message]
    ) -> [Message] {
        switch input.compactionStrategy {
        case .default:
            return branchAwareMiddleIfNeeded(input: input, middle: middle)
        case .iterativeDelta, .focused:
            return branchAwareMiddleIfNeeded(input: input, middle: middle)
        case .turnPrefix:
            guard let lastUserIndex = middle.lastIndex(where: { $0.role == .user }) else {
                return middle
            }
            // Keep latest turn boundary plus prior context to avoid slicing through active turn state.
            let prefix = Array(middle.prefix(through: lastUserIndex))
            return prefix.isEmpty ? middle : prefix
        case .branchAware:
            return branchAwareMiddleIfNeeded(input: input, middle: middle)
        }
    }

    private func branchAwareMiddleIfNeeded(input: ContextTransformInput, middle: [Message]) -> [Message] {
        guard input.branchParentConversationID != nil else { return middle }
        let marker = Message(
            id: UUID(),
            role: .system,
            content: "[BranchContext] Compaction is running on a branched conversation; preserve branch-local intent.",
            timestamp: Date(),
            toolCalls: []
        )
        return [marker] + middle
    }

    private func applyCacheAwarePruningIfConfigured(
        middle: [Message],
        cachePolicy: ContextCompactionCachePolicy?
    ) -> [Message] {
        guard let cachePolicy, cachePolicy.enabled else {
            return middle
        }
        let stablePrefixCount = min(max(0, cachePolicy.stablePrefixMessageCount), middle.count)
        let prefix = Array(middle.prefix(stablePrefixCount))
        var suffix = Array(middle.dropFirst(stablePrefixCount))
        if let ttl = cachePolicy.ttlSeconds, ttl > 0 {
            let cutoff = Date().addingTimeInterval(-ttl)
            suffix = suffix.filter { message in
                // Keep assistant/tool rows to avoid slicing through tool-call pair state.
                if message.role == .assistant || message.role == .tool {
                    return true
                }
                return message.timestamp >= cutoff
            }
        }
        return prefix + suffix
    }

    private func applyDeterministicPreCompactionHygiene(
        input: ContextTransformInput,
        head: [Message],
        middle: [Message],
        toolCallNameResolutionContext: [Message],
        includeToolResultPruning: Bool
    ) -> [Message] {
        var staged = applyStrategyPolicy(
            input: input,
            head: head,
            middle: middle
        )
        staged = applyCacheAwarePruningIfConfigured(
            middle: staged,
            cachePolicy: input.compactionCachePolicy
        )
        staged = applyAttachmentDocumentImageHygieneIfConfigured(
            middle: staged,
            policy: input.compactionDeterministicHygienePolicy
        )
        guard includeToolResultPruning,
              input.compactionDeterministicHygienePolicy?.toolResultPruningEnabled ?? true
        else {
            return staged
        }
        return ContextCompactionToolResultPruning
            .applyingToolResultContentPruningForCompactionLLM(
                messages: staged,
                toolNamesToPrune: Set(config.compactionToolResultPruneNames),
                maxRecentPerListedName: config.maxRecentPerNameToolResults,
                maxRecentUnlistedToolResults: config.maxRecentToolResults,
                toolCallNameResolutionContext: toolCallNameResolutionContext
            )
    }

    private func applyAttachmentDocumentImageHygieneIfConfigured(
        middle: [Message],
        policy: ContextCompactionDeterministicHygienePolicy?
    ) -> [Message] {
        ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: middle,
            policy: policy?.attachmentDocumentHygiene
        )
    }

    private func applyCompactionToolResultFormatting(_ result: ToolResult) -> ToolResult {
        let compactionFormatting = ToolResultFormattingStack.compactionConfiguration(
            base: toolResultFormattingConfiguration,
            compactionMaxCharactersOverride: config.toolResultSummarizationCharacterThreshold,
            compactionImagePlaceholderOverride: config.deterministicImagePlaceholder,
            compactionTruncationMarkerOverride: nil
        )
        return ToolResultFormattingStack.apply(
            result: result,
            stage: .compaction,
            configuration: compactionFormatting
        )
    }

    func transformToolResult(_ input: ToolResultTransformInput) async throws -> ToolResultTransformOutput {
        logger?.debug(
            "[ContextCompactionTransformer] transformToolResult input tool=\(input.toolCall.name) toolCallId=\(input.toolCall.id ?? "nil") resultChars=\(input.result.content.count)\n\(Self.describeToolResult(input.result))"
        )
        guard config.enabled else {
            let output = ToolResultTransformOutput(
                result: applyCompactionToolResultFormatting(input.result),
                diagnostics: "tool_result_summary_disabled"
            )
            logToolResultOutput(output)
            return output
        }
        guard input.result.content.count > config.toolResultSummarizationCharacterThreshold else {
            let output = ToolResultTransformOutput(
                result: applyCompactionToolResultFormatting(input.result),
                diagnostics: "tool_result_summary_noop_under_threshold"
            )
            logToolResultOutput(output)
            return output
        }
        do {
            logger?.info(
                "[ContextCompactionTransformer] LLM call: toolResultSummary tool=\(input.toolCall.name) resultChars=\(input.result.content.count) model=\(config.model)"
            )
            let preShapedRaw = applyCompactionToolResultFormatting(input.result)
            let summary = try await toolResultSummarizer.summarize(
                toolCall: input.toolCall,
                rawResult: preShapedRaw,
                conversation: input.conversation
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                let output = ToolResultTransformOutput(
                    result: applyCompactionToolResultFormatting(input.result),
                    diagnostics: "tool_result_summary_empty_output"
                )
                logToolResultOutput(output)
                return output
            }
            let summarizedResult = ToolResult(
                success: input.result.success,
                content: summary,
                metadata: input.result.metadata,
                toolCallId: input.result.toolCallId
            )
            let output = ToolResultTransformOutput(
                result: applyCompactionToolResultFormatting(summarizedResult),
                diagnostics: "tool_result_summarized"
            )
            logToolResultOutput(output)
            return output
        } catch {
            logger?.debug("[ContextCompactionTransformer] transformToolResult summarizer error: \(String(describing: error))")
            let output = ToolResultTransformOutput(
                result: applyCompactionToolResultFormatting(input.result),
                diagnostics: "tool_result_summary_failed"
            )
            logToolResultOutput(output)
            return output
        }
    }

    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        logger?.debug(
            "[ContextCompactionTransformer] transformTurnSummary input rangeStart=\(input.turnMessageRangeStartIndex) interactionMode=\(input.conversation.interactionMode.rawValue)\n\(Self.describeMessages(input.turnMessages))"
        )
        guard config.enabled else {
            let output = TurnSummaryTransformOutput(
                replacementTurnMessages: input.turnMessages,
                diagnostics: "turn_summary_disabled"
            )
            logTurnSummaryOutput(output)
            return output
        }
        guard !input.turnMessages.isEmpty else {
            let output = TurnSummaryTransformOutput(
                replacementTurnMessages: input.turnMessages,
                diagnostics: "turn_summary_noop_empty"
            )
            logTurnSummaryOutput(output)
            return output
        }

        do {
            logger?.info(
                "[ContextCompactionTransformer] LLM call: turnSummary messages=\(input.turnMessages.count) model=\(config.model)"
            )
            let decision = try await turnSummarizer.summarizeTurn(
                turnMessages: input.turnMessages,
                conversation: input.conversation
            )
            let summary = decision.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                let output = TurnSummaryTransformOutput(
                    replacementTurnMessages: input.turnMessages,
                    diagnostics: "turn_summary_empty_output"
                )
                logTurnSummaryOutput(output)
                return output
            }
            let summarizedTurnMessage = Message(
                id: UUID(),
                role: .assistant,
                content: summary,
                timestamp: Date(),
                toolCalls: []
            )
            // Preserve the initiating user message so the conversation thread retains
            // the original request that produced this summarized outcome.
            let preservedUserPrefix: [Message] = {
                guard let first = input.turnMessages.first, first.role == .user else {
                    return []
                }
                return [first]
            }()
            let output = TurnSummaryTransformOutput(
                replacementTurnMessages: preservedUserPrefix + [summarizedTurnMessage],
                diagnostics: decision.succeeded ? "turn_summary_success_result" : "turn_summary_failure_lessons_learned"
            )
            logTurnSummaryOutput(output)
            return output
        } catch {
            logger?.debug("[ContextCompactionTransformer] transformTurnSummary summarizer error: \(String(describing: error))")
            let output = TurnSummaryTransformOutput(
                replacementTurnMessages: input.turnMessages,
                diagnostics: "turn_summary_failed"
            )
            logTurnSummaryOutput(output)
            return output
        }
    }

    private static func validateCompactedMiddleMessages(_ messages: [Message], maxMessages: Int) -> [Message] {
        var out: [Message] = []
        for message in messages {
            if message.role == .system { continue }
            out.append(message)
            if out.count == maxMessages {
                break
            }
        }
        return out
    }

    private func passthroughOutput(messages: [Message], diagnostics: String?) -> ContextTransformOutput {
        ContextTransformOutput(
            messages: messages,
            diagnostics: diagnostics,
            messageProvenance: messages.map { message in
                ContextTransformMessageProvenance(
                    transformedMessageID: message.id,
                    origin: .original,
                    sourceMessageIDs: [message.id]
                )
            }
        )
    }

    private func logContextOutput(_ output: ContextTransformOutput) {
        logger?.debug(
            "[ContextCompactionTransformer] transformContext output diagnostics=\(output.diagnostics ?? "nil")\n\(Self.describeMessages(output.messages))"
        )
    }

    private func logToolResultOutput(_ output: ToolResultTransformOutput) {
        logger?.debug(
            "[ContextCompactionTransformer] transformToolResult output diagnostics=\(output.diagnostics ?? "nil") resultChars=\(output.result.content.count)\n\(Self.describeToolResult(output.result))"
        )
    }

    private func logTurnSummaryOutput(_ output: TurnSummaryTransformOutput) {
        logger?.debug(
            "[ContextCompactionTransformer] transformTurnSummary output diagnostics=\(output.diagnostics ?? "nil")\n\(Self.describeMessages(output.replacementTurnMessages))"
        )
    }

    private static func describeMessages(_ messages: [Message]) -> String {
        let lines = messages.enumerated().map { index, message in
            let trimmed = message.content.replacingOccurrences(of: "\n", with: "\\n")
            let preview = truncate(trimmed, maxCharacters: maxLoggedContentCharacters)
            return "[\(index)] id=\(message.id) role=\(message.role.rawValue) chars=\(message.content.count) toolCallId=\(message.toolCallId ?? "nil") content=\"\(preview)\""
        }
        return lines.joined(separator: "\n")
    }

    private static func describeToolResult(_ result: ToolResult) -> String {
        let trimmed = result.content.replacingOccurrences(of: "\n", with: "\\n")
        let preview = truncate(trimmed, maxCharacters: maxLoggedContentCharacters)
        return "success=\(result.success) toolCallId=\(result.toolCallId ?? "nil") content=\"\(preview)\""
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<end])…(truncated)"
    }
}

actor OllamaToolResultSummarizer: ToolResultSummarizing {
    private let config: ContextCompactionConfiguration
    private let logger: Logger?
    private let scheduling: ContextCompactionLLMScheduling?
    private var llm: (any LLMProtocol)?

    init(config: ContextCompactionConfiguration, logger: Logger?, scheduling: ContextCompactionLLMScheduling? = nil) {
        self.config = config
        self.logger = logger
        self.scheduling = scheduling
    }

    func summarize(
        toolCall: ToolCall,
        rawResult: ToolResult,
        conversation: ConversationTransformMetadata
    ) async throws -> String {
        let llm = try await resolveLLM()
        let intent = Self.toolIntentString(from: toolCall)
        let prompt = Message(
            id: UUID(),
            role: .user,
            content: """
            ToolIntent:
            \(intent)

            ConversationContext:
            - interactionMode: \(conversation.interactionMode.rawValue)
            - modelName: \(conversation.modelName)

            RawToolOutput:
            \(rawResult.content)

            Requirements:
            - Summarize only what helps satisfy why this tool call was made.
            - Preserve critical literals: IDs, URLs, file paths, error strings, and important numbers.
            - Mark uncertainty explicitly if output is ambiguous or partial.
            - Exclude irrelevant verbose detail.
            - Return concise plain text only; no markdown wrappers.
            """
        )
        let system = Message(
            id: UUID(),
            role: .system,
            content: """
            You are an intent-aware tool result summarizer.
            Your summary should optimize usefulness for the next LLM step.
            Do not invent details not present in ToolIntent or RawToolOutput.
            """
        )
        let response = try await llm.send([system, prompt], config: .harnessTagged(.contextCompactionToolResult))
        return response.content
    }

    private func resolveLLM() async throws -> any LLMProtocol {
        if let llm {
            return llm
        }
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true,
            logger: logger,
            interactionMode: .chat
        )
        let base = OllamaLLM(
            model: config.model,
            serverURL: config.ollamaServerURL,
            capabilities: [.completion],
            systemPrompt: prompt,
            logger: logger
        )
        let resolved = wrapCompactionLLMForScheduling(base, scheduling: scheduling)
        llm = resolved
        return resolved
    }

    private static func toolIntentString(from toolCall: ToolCall) -> String {
        let args = toolCall.arguments
        let argsString: String
        if let data = try? JSONEncoder().encode(args),
           let str = String(data: data, encoding: .utf8) {
            argsString = str
        } else {
            argsString = "{}"
        }
        return "tool=\(toolCall.name)\narguments=\(argsString)"
    }
}

enum OllamaContextCompactionSummarizerError: Error, Sendable, LocalizedError {
    /// Loop terminated without a successful response and `lastError` was somehow nil.
    /// In normal operation a thrown error is always re-thrown directly, so this is
    /// only seen if the loop body changes in the future.
    case exhaustedOversizeRetries

    var errorDescription: String? {
        switch self {
        case .exhaustedOversizeRetries:
            return "Compaction summarizer exhausted oversize retry attempts without producing output."
        }
    }
}

actor OllamaContextCompactionSummarizer: ContextCompactionSummarizing {
    private let config: ContextCompactionConfiguration
    private let logger: Logger?
    private let scheduling: ContextCompactionLLMScheduling?
    private var llm: (any LLMProtocol)?

    init(config: ContextCompactionConfiguration, logger: Logger?, scheduling: ContextCompactionLLMScheduling? = nil) {
        self.config = config
        self.logger = logger
        self.scheduling = scheduling
    }

    /// Convenience entry point used by callers that don't pass an override. Required by the
    /// `ContextCompactionSummarizing` protocol; delegates to the extended core implementation.
    func summarizeMiddle(messages: [Message], maxMessages: Int, debugOutputPath: String?) async throws -> [Message] {
        try await summarizeMiddle(
            messages: messages,
            maxMessages: maxMessages,
            debugOutputPath: debugOutputPath,
            customInstructionsOverride: nil,
            identifierPreservationPolicy: nil,
            previousSummaryText: nil,
            summaryBudgetTokens: config.compactionSummaryBudgetTokens,
            maxOutputTokens: config.resolvedSummarizerMaxOutputTokens
        )
    }

    func summarizeMiddle(
        messages: [Message],
        maxMessages: Int,
        debugOutputPath: String?,
        customInstructionsOverride: String?,
        identifierPreservationPolicy: ContextCompactionIdentifierPreservationPolicy?,
        previousSummaryText: String?,
        summaryBudgetTokens: Int,
        maxOutputTokens: Int
    ) async throws -> [Message] {
        guard !messages.isEmpty else { return [] }
        let llm = try await resolveLLM()
        // `workingMiddle` is recreated from the `messages` parameter on every call. We never store
        // it on `self`; subsequent invocations always start with the full incoming middle (state
        // hygiene invariant).
        var workingMiddle = messages

        let instruction = Message(
            id: UUID(),
            role: .system,
            content: """
            You are a context summarization agent. Your output will replace the
            earlier portion of a conversation between a user and an AI assistant,
            and will be read by a DIFFERENT assistant that continues the work
            from where this one left off. Treat your output as a handoff — it
            must give the next assistant everything they need to resume without
            re-asking questions or repeating completed work.

            # Output rules

            - Respond with plain text only. Do NOT call any tools, invoke any
              function, or spawn any agent. You already have all the context you
              need from the conversation above. Tool calls will be rejected and
              will waste your only turn.
            - Do NOT continue the conversation. Do NOT answer questions, fulfill
              requests, or react to anything in the messages above — that work
              belongs to the next assistant, not you.
            - Do NOT include any preamble, greeting, meta-commentary, or sign-off.
              Begin directly with the required output structure.
            - Write in the same language the user was using. Do not translate or
              switch to English.
            - Follow the section structure in the user message exactly. Every
              section must be present; if a section has no content, write "None."
              rather than omitting it.

            # Faithfulness

            - Only include information present in the conversation above. Do NOT
              invent file paths, function names, line numbers, error messages,
              decisions, or commitments. If you are tempted to fill a gap with a
              plausible guess, write "unknown" instead.
            - When a fact is uncertain or partial, say so explicitly ("test
              status unknown — last run failed mid-suite") rather than asserting it.
            - Preserve the user's exact wording where it matters: their requests,
              corrections, constraints, and preferences. The next assistant should
              be able to read your summary and know exactly what the user asked for.
            - Distinguish completed work from in-progress work from
              discussed-but-not-done work. Conflating these is the most common way
              a summary misleads the next assistant.

            # Security

            Never include API keys, tokens, passwords, secrets, credentials,
            connection strings, or any value that appears to be a credential.
            Replace them with [REDACTED]. If credentials were discussed, note
            that they exist (so the next assistant has the context) but do not
            preserve the values.

            # Method

            First, draft inside <analysis> tags: walk the conversation
            chronologically and identify what happened, what's pending, and what
            state things ended in. Then produce the final structured summary
            inside <summary> tags using the exact format from the user message.
            The <analysis> block is your scratchpad — only the <summary> block
            will be passed to the next assistant.
            """
        )
        let customInstructionsBlock = customInstructionsOverride ?? config.compactionCustomInstructionsBlock
        let identifierPreservationBlock = Self.identifierPreservationPromptBlock(
            policy: identifierPreservationPolicy
        )
        let previousSummaryBlock = Self.previousSummaryPromptBlock(previousSummaryText: previousSummaryText)
        let userPrompt = DynamicPrompt(
            template: ContextCompactionHandoffUserPromptTemplate.value,
            defaultTokens: [
                "summary_budget": String(summaryBudgetTokens),
                "identifier_preservation_block": identifierPreservationBlock,
                "custom_instructions_block": customInstructionsBlock,
                "previous_summary_block": previousSummaryBlock,
            ]
        )
        let handoffRendered = userPrompt.render()
        let prompt = Message(
            id: UUID(),
            role: .user,
            content: handoffRendered
        )

        let debugRunDirectory: URL? = {
            guard let raw = debugOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return ContextCompactionSummarizerDebugCapture.makeRunDirectory(basePath: raw, logger: logger)
        }()

        let maxAttempts = max(1, config.oversizeRetryMaxAttempts)
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            let llmMessages = [instruction] + workingMiddle + [prompt]
            if let dir = debugRunDirectory {
                do {
                    try ContextCompactionSummarizerDebugCapture.writeInput(
                        directory: dir,
                        model: config.model,
                        maxMessages: maxMessages,
                        systemInstruction: instruction.content,
                        middleMessages: workingMiddle,
                        handoffUserContent: handoffRendered
                    )
                } catch {
                    logger?.warning("[ContextCompactionSummarizer] debug input write failed: \(String(describing: error))")
                }
            }

            do {
                let tagged = LLMRequestConfig.harnessTagged(.contextCompactionSummarizeMiddle)
                let requestConfig = LLMRequestConfig(
                    maxTokens: maxOutputTokens,
                    additionalParameters: tagged.additionalParameters
                )
                let response = try await llm.send(llmMessages, config: requestConfig)
                if let dir = debugRunDirectory {
                    do {
                        try ContextCompactionSummarizerDebugCapture.writeOutput(
                            directory: dir,
                            rawResponse: response.content
                        )
                    } catch {
                        logger?.warning("[ContextCompactionSummarizer] debug output write failed: \(String(describing: error))")
                    }
                }
                return Self.decodeHandoffMessages(from: response.content, maxMessages: maxMessages)
            } catch {
                lastError = error
                let isContextWindow = ContextCompactionErrorMatcher.isContextWindowExceeded(error, patterns: config.reactiveErrorPatterns)
                let hasMoreAttempts = attempt + 1 < maxAttempts
                if isContextWindow, hasMoreAttempts {
                    logger?.warning(
                        "[ContextCompactionSummarizer] Compaction LLM rejected payload as too large (attempt \(attempt + 1)/\(maxAttempts)); shrinking middle and retrying: \(String(describing: error))"
                    )
                    workingMiddle = Self.dropOldestGroups(
                        workingMiddle,
                        fraction: config.oversizeRetryDropFraction,
                        marker: config.oversizeRetryMarker
                    )
                    continue
                }
                if let dir = debugRunDirectory {
                    do {
                        try ContextCompactionSummarizerDebugCapture.writeOutput(
                            directory: dir,
                            rawResponse: "(LLM call failed: \(String(describing: error)))"
                        )
                    } catch {
                        logger?.warning("[ContextCompactionSummarizer] debug output write failed: \(String(describing: error))")
                    }
                }
                throw error
            }
        }
        // Loop exit without success means we exhausted retries on context-window errors.
        throw lastError ?? OllamaContextCompactionSummarizerError.exhaustedOversizeRetries
    }

    static func previousSummaryPromptBlock(previousSummaryText: String?) -> String {
        let trimmed = previousSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        return """
        Below is an existing context summary, followed by new conversation turns that have occurred since it was written.

        <previous-summary>
        \(trimmed)
        </previous-summary>

        Update the summary to incorporate the new turns. For each section:
        - Move items from "In Progress" to "Completed Actions" if they are now done.
        - Continue the numbering in "Completed Actions" — do not restart from 1.
        - Add new context to "Critical Context" and file sections where appropriate.
        - Update "Active Task" to reflect the user's current request.
        - Remove resolved items from "Blocked" and "Pending User Asks".
        Preserve all existing content unless it is explicitly superseded.

        """
    }

    static func identifierPreservationPromptBlock(
        policy: ContextCompactionIdentifierPreservationPolicy?
    ) -> String {
        let resolved = policy ?? ContextCompactionIdentifierPreservationPolicy(
            mode: .strict,
            customInstructions: nil
        )
        switch resolved.mode {
        case .off:
            return ""
        case .strict:
            return """
            # Identifier preservation

            Preserve opaque identifiers exactly as they appear in the source context.
            Never normalize, abbreviate, transform, or reformat IDs (for example:
            UUIDs, run IDs, checkpoint IDs, tool call IDs, hashes, error IDs, and
            similarly opaque tokens).
            """
        case .custom:
            let custom = resolved.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            let customLine: String
            if let custom, !custom.isEmpty {
                customLine = "\n\nAdditional rules:\n\(custom)"
            } else {
                customLine = ""
            }
            return """
            # Identifier preservation

            Preserve opaque identifiers exactly as they appear in the source context.
            Never normalize, abbreviate, transform, or reformat IDs (for example:
            UUIDs, run IDs, checkpoint IDs, tool call IDs, hashes, error IDs, and
            similarly opaque tokens).\(customLine)
            """
        }
    }

    /// Drops the oldest `floor(N * fraction)` items from `messages` and prepends a single synthetic
    /// user-role marker message. Idempotent on the marker: if the first message is already the
    /// oversize-retry marker it is removed first so we don't double-prefix on each retry.
    ///
    /// Edge cases:
    /// - 0 messages → returns `[]` unchanged (no marker; caller short-circuits).
    /// - 1 message → drops 0; returned with a single marker prepended.
    /// - any `fraction <= 0` or `fraction >= 1` → clamped to (0, 0.95).
    static func dropOldestGroups(_ messages: [Message], fraction: Double, marker: String) -> [Message] {
        guard !messages.isEmpty else { return [] }
        var working = messages
        // Strip a previously-prepended marker so successive retries don't accumulate prefixes.
        if let first = working.first, first.role == .user, first.content == marker {
            working.removeFirst()
        }
        if working.isEmpty {
            return [Self.makeRetryMarkerMessage(marker)]
        }
        let clamped = max(0, min(0.95, fraction))
        let dropCount = Int(floor(Double(working.count) * clamped))
        if dropCount > 0 {
            working.removeFirst(min(dropCount, working.count))
        }
        return [Self.makeRetryMarkerMessage(marker)] + working
    }

    private static func makeRetryMarkerMessage(_ marker: String) -> Message {
        Message(
            id: UUID(),
            role: .user,
            content: marker,
            timestamp: Date(),
            toolCalls: []
        )
    }

    private func resolveLLM() async throws -> any LLMProtocol {
        if let llm {
            return llm
        }
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true,
            logger: logger,
            interactionMode: .chat
        )
        let base = OllamaLLM(
            model: config.model,
            serverURL: config.ollamaServerURL,
            capabilities: [.completion],
            systemPrompt: prompt,
            logger: logger
        )
        let resolved = wrapCompactionLLMForScheduling(base, scheduling: scheduling)
        llm = resolved
        return resolved
    }

    /// Prefer `<summary>…</summary>`; if missing, strip `<analysis>…</analysis>` and use the remainder, else the full trimmed response.
    private static func decodeHandoffMessages(from text: String, maxMessages: Int) -> [Message] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxMessages > 0 else { return [] }

        let content: String = {
            if let extracted = extractTagContent(trimmed, tag: "summary"), !extracted.isEmpty {
                return extracted
            }
            let withoutAnalysis = stripXMLStyleBlock(text: trimmed, tag: "analysis")
            let after = withoutAnalysis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty, after != trimmed {
                return after
            }
            return trimmed
        }()
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            return []
        }

        let handoff = Message(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            toolCalls: []
        )
        return [handoff]
    }

    private static func extractTagContent(_ text: String, tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let startOpen = text.range(of: open, options: .caseInsensitive),
              let endClose = text.range(of: close, options: .caseInsensitive, range: startOpen.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startOpen.upperBound..<endClose.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripXMLStyleBlock(text: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = text
        while let s = result.range(of: open, options: .caseInsensitive),
              let e = result.range(of: close, options: .caseInsensitive, range: s.upperBound..<result.endIndex) {
            result.removeSubrange(s.lowerBound..<e.upperBound)
        }
        return result
    }
}

actor OllamaTurnSummarizer: TurnSummarizing {
    private let config: ContextCompactionConfiguration
    private let logger: Logger?
    private let scheduling: ContextCompactionLLMScheduling?
    private var llm: (any LLMProtocol)?

    init(config: ContextCompactionConfiguration, logger: Logger?, scheduling: ContextCompactionLLMScheduling? = nil) {
        self.config = config
        self.logger = logger
        self.scheduling = scheduling
    }

    func summarizeTurn(
        turnMessages: [Message],
        conversation: ConversationTransformMetadata
    ) async throws -> TurnSummaryDecision {
        guard !turnMessages.isEmpty else {
            return TurnSummaryDecision(succeeded: false, summary: "")
        }
        let llm = try await resolveLLM()
        let transcript = turnMessages.enumerated().map { index, message in
            "[\(index)] role=\(message.role.rawValue) toolCallId=\(message.toolCallId ?? "nil")\n\(message.content)"
        }.joined(separator: "\n\n")
        let system = Message(
            id: UUID(),
            role: .system,
            content: """
            You are a turn outcome summarizer for an autonomous agent loop.
            Evaluate whether the turn achieved its goal and produce a concise summary.
            Do not invent facts not present in the turn transcript.
            Return strict JSON only (no markdown fences, no prose):
            {
              "succeeded": <true|false>,
              "summary": "<plain text summary>"
            }
            """
        )
        let prompt = Message(
            id: UUID(),
            role: .user,
            content: """
            ConversationContext:
            - interactionMode: \(conversation.interactionMode.rawValue)
            - modelName: \(conversation.modelName)

            TurnTranscript:
            \(transcript)

            Instructions:
            1) Determine if the turn successfully accomplished what it set out to do.
            2) If succeeded=true:
               - summary should contain only the successful result/outcome.
               - keep it concise and actionable.
            3) If succeeded=false:
               - summary must explain what went wrong.
               - include mistakes that may have been made.
               - include lessons learned for achieving the goal next time.
            4) Preserve critical literals (IDs, paths, URLs, exact error strings, important numbers) when relevant.
            5) Output ONLY the required JSON object.
            """
        )
        let response = try await llm.send([system, prompt], config: .harnessTagged(.contextCompactionTurnSummary))
        return try Self.decodeDecision(from: response.content)
    }

    private func resolveLLM() async throws -> any LLMProtocol {
        if let llm {
            return llm
        }
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true,
            logger: logger,
            interactionMode: .chat
        )
        let base = OllamaLLM(
            model: config.model,
            serverURL: config.ollamaServerURL,
            capabilities: [.completion],
            systemPrompt: prompt,
            logger: logger
        )
        let resolved = wrapCompactionLLMForScheduling(base, scheduling: scheduling)
        llm = resolved
        return resolved
    }

    private struct JSONDecision: Decodable {
        let succeeded: Bool
        let summary: String
    }

    private static func decodeDecision(from text: String) throws -> TurnSummaryDecision {
        let jsonText = extractJSONObjectText(from: text) ?? text
        guard let data = jsonText.data(using: .utf8) else {
            throw TurnSummaryParseError.invalidJSONEncoding
        }
        let parsed = try JSONDecoder().decode(JSONDecision.self, from: data)
        return TurnSummaryDecision(succeeded: parsed.succeeded, summary: parsed.summary)
    }

    private static func extractJSONObjectText(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private enum TurnSummaryParseError: Error {
        case invalidJSONEncoding
    }
}
