import Foundation
import SwiftAgentKit

// Context compaction checkpoint payloads and selection (`context_compaction_checkpoint` events).
// Distinct from turn-summary UI projection (different event kinds and payloads).

// MARK: - Kind

/// Distinguishes how the persisted middle was produced. Drives the reuse path:
/// - `.summarized` checkpoints replace their covered raw messages with synthesized text and on
///   the next compaction the synthesized prefix is preserved verbatim while only the new raw
///   tail is processed.
/// - `.pruned` checkpoints store the original messages with tool-result content cleared
///   (placeholder substituted) and on the next compaction the deterministic prune step is
///   skipped — the effective middle goes straight to LLM summarization.
public enum ContextCompactionCheckpointKind: String, Codable, Sendable {
    case summarized
    case pruned

    /// Diagnostic emitted by `ContextCompactionTransformer` for a full LLM-summarized run.
    static let summarizedDiagnostic = "context_compacted"
    /// Diagnostic emitted by `ContextCompactionTransformer` when deterministic pruning alone
    /// brought the conversation under the proactive token threshold (no LLM call).
    static let prunedDiagnostic = "context_compacted_pruned"
    static let memorySwapDiagnostic = "context_compacted_memory_swap"

    /// Maps a transformer `output.diagnostics` value to the kind that should be persisted, or
    /// `nil` if the diagnostic does not represent a successful compaction.
    static func fromDiagnostic(_ diagnostic: String?) -> ContextCompactionCheckpointKind? {
        switch diagnostic {
        case summarizedDiagnostic: return .summarized
        case prunedDiagnostic, memorySwapDiagnostic: return .pruned
        default: return nil
        }
    }
}

// MARK: - Payload (persisted in CachedConversationEvent)

struct ContextCompactionCheckpointPayload: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    /// Distinguishes pruned-only checkpoints from full LLM-summarized checkpoints.
    let kind: ContextCompactionCheckpointKind
    /// Ordered raw `Message.id` values from the base transcript that this checkpoint replaces (full middle slice at time of compaction).
    let coveredMessageIDs: [UUID]
    let syntheticMessages: [ContextCompactionMessageDTO]
    let configFingerprint: String
    let basedOnEventID: Int
    /// Tail raw ``Message.id`` for the covered slice (harness anchor for branch inheritance).
    let basedOnTailMessageID: UUID?
    /// Summarization strategy used to produce this checkpoint (`default` when absent).
    let strategyRawValue: String?
    /// Cache-aware pruning fingerprint for strategy/cache policy compatibility checks.
    let cachePolicyFingerprint: String?
    let createdAt: Date

    init(
        schemaVersion: Int = ContextCompactionCheckpointPayload.currentSchemaVersion,
        kind: ContextCompactionCheckpointKind,
        coveredMessageIDs: [UUID],
        syntheticMessages: [ContextCompactionMessageDTO],
        configFingerprint: String,
        basedOnEventID: Int,
        basedOnTailMessageID: UUID? = nil,
        strategyRawValue: String? = nil,
        cachePolicyFingerprint: String? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.coveredMessageIDs = coveredMessageIDs
        self.syntheticMessages = syntheticMessages
        self.configFingerprint = configFingerprint
        self.basedOnEventID = basedOnEventID
        self.basedOnTailMessageID = basedOnTailMessageID ?? coveredMessageIDs.last
        self.strategyRawValue = strategyRawValue
        self.cachePolicyFingerprint = cachePolicyFingerprint
        self.createdAt = createdAt
    }
}

/// Minimal message shape for checkpoint JSON. Synthesized (`.summarized`) checkpoints use only
/// `id` / `role` / `content`. Pruned (`.pruned`) checkpoints additionally persist `toolCalls`
/// and `toolCallId` so the rehydrated assistant/tool messages remain valid for the agent loop
/// after reuse. Equatable conformance is implemented manually because `ToolCall.arguments` is an
/// `EasyJSON.JSON` value that does not conform to `Equatable`; we compare by canonical JSON
/// encoding instead, which is sufficient for tests and assertion paths.
struct ContextCompactionMessageDTO: Codable, Sendable, Equatable {
    let id: UUID
    let role: String
    let content: String
    let toolCalls: [ToolCall]?
    let toolCallId: String?

    static func == (lhs: ContextCompactionMessageDTO, rhs: ContextCompactionMessageDTO) -> Bool {
        guard lhs.id == rhs.id,
              lhs.role == rhs.role,
              lhs.content == rhs.content,
              lhs.toolCallId == rhs.toolCallId
        else { return false }
        return ContextCompactionMessageDTO.toolCallsEqual(lhs.toolCalls, rhs.toolCalls)
    }

    /// Compares two optional `[ToolCall]` lists for value equality. Falls back to canonical JSON
    /// encoding because `ToolCall.arguments` (`EasyJSON.JSON`) is not `Equatable`.
    private static func toolCallsEqual(_ a: [ToolCall]?, _ b: [ToolCall]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let l?, let r?):
            guard l.count == r.count else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for (lhs, rhs) in zip(l, r) {
                guard let ld = try? encoder.encode(lhs),
                      let rd = try? encoder.encode(rhs),
                      ld == rd else { return false }
            }
            return true
        default: return false
        }
    }

    init(
        id: UUID,
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Used for `.summarized` checkpoints — strips tool-call metadata since synthesized text has
    /// no real underlying tool call.
    init(message: Message) {
        self.id = message.id
        self.role = message.role.rawValue
        self.content = message.content
        self.toolCalls = nil
        self.toolCallId = nil
    }

    /// Used for `.pruned` checkpoints — preserves `toolCalls` and `toolCallId` so the agent loop
    /// can still resolve tool-call/result pairs when the prefix is fed back as the effective
    /// middle on a subsequent compaction.
    static func prunedDTO(from message: Message) -> ContextCompactionMessageDTO {
        ContextCompactionMessageDTO(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            toolCalls: message.toolCalls.isEmpty ? nil : message.toolCalls,
            toolCallId: message.toolCallId
        )
    }

    func toMessage() -> Message {
        Message(
            id: id,
            role: MessageRole(rawValue: role) ?? .assistant,
            content: content,
            timestamp: Date(),
            toolCalls: toolCalls ?? [],
            toolCallId: toolCallId
        )
    }
}

// MARK: - Fingerprint & assembly

enum ContextCompactionCheckpointSupport {
    /// Stable string over every field that affects compaction LLM behavior, gating, or eligibility.
    static func configFingerprint(_ config: ContextCompactionConfiguration) -> String {
        [
            config.enabled,
            config.ollamaServerURL.absoluteString,
            config.model,
            config.fallbackContextLimitTokens,
            config.charactersPerToken,
            config.maxCompactedMiddleMessages,
            config.middleMinCharactersForCompactionLLM,
            Int(config.compactionLLMCooldownSeconds * 1000),
            config.compactionToolResultPruneNames.sorted().joined(separator: ","),
            config.maxRecentToolResults,
            config.maxRecentPerNameToolResults,
            config.toolResultPruneReplacementMode.rawValue,
            config.compactionSummaryBudgetTokens,
            config.compactionCustomInstructionsBlock,
            config.compactionSummarizerContextLimitTokens,
            config.proactiveSafetyBufferTokens,
            config.proactiveOutputReserveTokens,
            config.reactiveTriggerEnabled,
            config.reactiveErrorPatterns.joined(separator: ","),
            config.oversizeRetryMaxAttempts,
            config.oversizeRetryDropFraction,
            config.oversizeRetryMarker,
            config.manualToolEnabled,
            config.manualToolMinUtilization,
            config.manualSlashEnabled,
            config.manualRESTEnabled,
            config.defaultSummarizationStrategy,
            config.focusedCompactionQuery,
            config.cacheAwarePruningEnabled,
            config.cacheStablePrefixMessageCount,
            config.cachePruningTTLSeconds.map { String(describing: $0) } ?? "",
            config.deterministicToolResultPruningEnabled,
            config.deterministicAttachmentDocumentHygieneEnabled,
            config.deterministicMaxImagesPerMessage,
            config.deterministicDocumentCharacterThreshold,
            config.deterministicDocumentPlaceholder,
            config.deterministicImagePlaceholder,
            config.optionalCompactionProviderSlot ?? "",
            config.optionalCompactionProviderFallbackToOllama,
            config.headMinMessageCount,
            config.tailMinMessageCount,
            config.tailTokenBudgetFraction,
            config.resolvedSummarizerMaxOutputTokens,
            config.compactionSummaryBudgetProportionalEnabled,
            config.sessionMemorySwapBeforeCompactionEnabled,
            config.compactionReinjectionEnabled,
            config.reinjectionRecentFileCount,
            config.reinjectionPerFileTokenBudget,
            config.reinjectionTotalFileTokenBudget,
            config.reinjectionPerSkillTokenBudget,
            config.reinjectionTotalSkillTokenBudget,
            config.reinjectFileContentEnabled,
            config.compactionCircuitBreakerMaxFailures,
            config.compactionMinPromptTokenSavingsFraction,
            config.useSessionTreeProjection,
        ].map { String(describing: $0) }.joined(separator: "|")
    }

    /// Head / middle / tail definition lives in `ContextCompactionMessageSplit` (Compaction/).
    typealias CompactionMessageSegments = ContextCompactionMessageSegments

    static func splitForCompaction(
        _ messages: [Message],
        config: ContextCompactionConfiguration,
        modelContextLimitTokens: Int
    ) -> CompactionMessageSegments {
        var options = ContextCompactionPolicy.resolvedSplitOptions(
            modelContextLimitTokens: modelContextLimitTokens,
            config: config
        )
        options.headMinMessageCount = config.headMinMessageCount
        options.tailMinMessageCount = config.tailMinMessageCount
        return ContextCompactionMessageSplit.splitForCompaction(messages, options: options)
    }

    static func rawMiddle(
        from messages: [Message],
        config: ContextCompactionConfiguration,
        modelContextLimitTokens: Int
    ) -> [Message] {
        splitForCompaction(messages, config: config, modelContextLimitTokens: modelContextLimitTokens).middle
    }

    /// Strips harness-injected system messages so they never enter coveredMessageIDs.
    static func transcriptForCompactionCoverage(_ messages: [Message]) -> [Message] {
        messages.filter { !HarnessInjectedMessageMetadata.isHarnessInjected($0) }
    }

    static func partitionForCompaction(_ messages: [Message]) -> (injected: [Message], transcript: [Message]) {
        let transcript = transcriptForCompactionCoverage(messages)
        let transcriptIDs = Set(transcript.map(\.id))
        let injected = messages.filter { !transcriptIDs.contains($0.id) }
        return (injected, transcript)
    }

    /// Synthesized middle from a compacted `output` where layout is `prefix + head + middleSegment + tail`.
    /// `middleSegment` is the compacted payload (summary and/or reinjection when enabled).
    static func compactedPortionInOutput(_ output: [Message], headCount: Int, tailCount: Int) -> [Message] {
        guard !output.isEmpty, headCount + tailCount <= output.count else { return [] }
        return Array(output.dropFirst(headCount).dropLast(tailCount))
    }

    /// Checkpoint persistence is summary-only; reinjection messages are per-call projection artifacts.
    static func durableCompactedMiddleForPersistence(
        compactedMiddle: [Message],
        messageProvenance: [ContextTransformMessageProvenance]?
    ) -> [Message] {
        guard let messageProvenance else { return compactedMiddle }
        let reinjectedIDs = Set(
            messageProvenance.filter { $0.origin == .reinjected }.map(\.transformedMessageID)
        )
        guard !reinjectedIDs.isEmpty else { return compactedMiddle }
        return compactedMiddle.filter { !reinjectedIDs.contains($0.id) }
    }

    static let compactionCheckpointPersistenceSizeSlack = ContextCompactionConfiguration.checkpointPersistenceSizeSlack

    /// Rejects summarized checkpoint payloads that exceed the summary budget or grow relative to the prior summary.
    static func compactionCheckpointPersistencePassesSizeGuards(
        compactedMiddle: [Message],
        config: ContextCompactionConfiguration,
        previousSummaryText: String?,
        kind: ContextCompactionCheckpointKind
    ) -> Bool {
        guard kind == .summarized else { return true }
        let cpt = config.charactersPerToken
        let middleTokens = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: compactedMiddle,
            charactersPerToken: cpt
        )
        let maxTokens = config.compactionPersistenceTokenCeiling
        if middleTokens > maxTokens {
            return false
        }
        let trimmedPrior = previousSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPrior.isEmpty else { return true }
        let priorMessage = Message(
            id: UUID(),
            role: .assistant,
            content: trimmedPrior,
            timestamp: Date(),
            toolCalls: []
        )
        let priorTokens = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: [priorMessage],
            charactersPerToken: cpt
        )
        let growthCeiling = Int(Double(priorTokens) * compactionCheckpointPersistenceSizeSlack)
        return middleTokens < growthCeiling
    }

    static func meetsPromptTokenSavingsThreshold(
        tokensBefore: Int,
        tokensAfter: Int,
        config: ContextCompactionConfiguration
    ) -> Bool {
        let fraction = config.compactionMinPromptTokenSavingsFraction
        guard fraction > 0, tokensBefore > 0 else { return true }
        let minSavings = Int(floor(Double(tokensBefore) * fraction))
        return tokensBefore - tokensAfter >= minSavings
    }

    static func estimatedMiddleCharacters(_ middle: [Message]) -> Int {
        middle.reduce(0) { $0 + $1.content.count }
    }

    /// Largest global journal event id such that invalidation markers at or below it supersede derived artifacts
    /// matching **any** of `invalidatedKindKeys` (empty payload `kinds` applies to all readers).
    static func derivedInvalidationFloor(events: [CachedConversationEvent], invalidatedKindKeys: [String]) -> Int {
        let invalidatedKind = ConversationEventKind.checkpointInvalidated.rawValue
        let keySet = Set(invalidatedKindKeys)
        var maxID = 0
        for event in events where event.kind == invalidatedKind {
            guard let payload = ConversationEventCodec.decode(CheckpointInvalidatedEventPayload.self, from: event.payloadJSON) else {
                continue
            }
            let applies: Bool
            if payload.kinds.isEmpty {
                applies = true
            } else {
                applies = !keySet.isDisjoint(with: Set(payload.kinds))
            }
            if applies {
                maxID = max(maxID, event.eventID)
            }
        }
        return maxID
    }

    /// Largest derived-event ID such that all compaction checkpoints at or below it are superseded by invalidation.
    static func contextCompactionCheckpointInvalidationFloor(events: [CachedConversationEvent]) -> Int {
        DerivedArtifactContractMatrix.invalidationFloor(
            events: events,
            forPersistedKind: ConversationEventKind.contextCompactionCheckpoint.rawValue
        )
    }

    /// If a **still-valid** persisted compaction checkpoint (above invalidation floor) matches the proposed
    /// write exactly—same ordered coverage, kind, config fingerprint, and synthetic payload—returns its
    /// `eventID` so ``RoutingDerivedEventStore/appendContextCompactionCheckpoint`` can no-op (idempotent retry).
    static func matchingIdempotentContextCompactionCheckpointEventID(
        events: [CachedConversationEvent],
        coveredMessageIDs: [UUID],
        syntheticMessages: [ContextCompactionMessageDTO],
        kind: ContextCompactionCheckpointKind,
        configFingerprint: String,
        strategyRawValue: String? = nil,
        cachePolicyFingerprint: String? = nil
    ) -> Int? {
        let floor = contextCompactionCheckpointInvalidationFloor(events: events)
        let tail = coveredMessageIDs.last
        for event in events
            .filter({ $0.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue && $0.eventID > floor })
            .sorted(by: { $0.eventID > $1.eventID })
        {
            guard let payload = ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: event.payloadJSON),
                  payload.schemaVersion == ContextCompactionCheckpointPayload.currentSchemaVersion
            else { continue }
            guard payload.kind == kind,
                  payload.configFingerprint == configFingerprint,
                  payload.coveredMessageIDs == coveredMessageIDs,
                  payload.syntheticMessages == syntheticMessages,
                  payload.strategyRawValue == strategyRawValue,
                  payload.cachePolicyFingerprint == cachePolicyFingerprint
            else { continue }
            let payloadTail = payload.basedOnTailMessageID ?? payload.coveredMessageIDs.last
            guard payloadTail == tail else { continue }
            return event.eventID
        }
        return nil
    }

    /// Latest valid checkpoint for this raw middle and config (highest `eventID` first).
    /// - Parameter frontierEventID: Log tail from the same load as `events` (e.g. store `MAX(eventID)`). Pass `nil` only when `events` is a complete per-conversation stream; otherwise pass the authoritative tail.
    static func latestValidCheckpoint(
        events: [CachedConversationEvent],
        rawMiddle: [Message],
        config: ContextCompactionConfiguration,
        expectedStrategyRawValue: String? = nil,
        frontierEventID: Int? = nil
    ) -> (payload: ContextCompactionCheckpointPayload, eventID: Int)? {
        let resolvedFrontier = frontierEventID ?? (events.map(\.eventID).max() ?? 0)
        let invalidationFloor = contextCompactionCheckpointInvalidationFloor(events: events)
        let rawIDs = rawMiddle.map(\.id)
        let fp = configFingerprint(config)
        let candidates = events
            .filter { $0.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue }
            .sorted { $0.eventID > $1.eventID }
        for event in candidates {
            guard event.eventID > invalidationFloor else { continue }
            guard let payload = ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: event.payloadJSON),
                  payload.schemaVersion == ContextCompactionCheckpointPayload.currentSchemaVersion,
                  payload.configFingerprint == fp,
                  !payload.coveredMessageIDs.isEmpty,
                  payload.syntheticMessages.count == payload.coveredMessageIDs.count,
                  payload.basedOnEventID <= resolvedFrontier
            else { continue }
            let prefixCount = payload.coveredMessageIDs.count
            guard rawIDs.count >= prefixCount,
                  Array(rawIDs.prefix(prefixCount)) == payload.coveredMessageIDs
            else { continue }
            if let anchorTail = payload.basedOnTailMessageID,
               payload.coveredMessageIDs.last != anchorTail {
                continue
            }
            if let expectedStrategyRawValue {
                let stored = payload.strategyRawValue ?? ContextCompactionStrategy.default.rawValue
                if stored != expectedStrategyRawValue {
                    continue
                }
            }
            return (payload, event.eventID)
        }
        return nil
    }

    /// Builds the middle list fed to the compaction LLM: prior synthesis + raw tail after checkpoint prefix.
    static func effectiveMiddle(
        rawMiddle: [Message],
        checkpoint: ContextCompactionCheckpointPayload?
    ) -> (middle: [Message], isIncremental: Bool) {
        guard let checkpoint else {
            return (rawMiddle, false)
        }
        let rawIDs = rawMiddle.map(\.id)
        let k = checkpoint.coveredMessageIDs.count
        guard k <= rawMiddle.count,
              k <= rawIDs.count,
              checkpoint.syntheticMessages.count == k,
              Array(rawIDs.prefix(k)) == checkpoint.coveredMessageIDs
        else {
            return (rawMiddle, false)
        }
        let tail = Array(rawMiddle.dropFirst(k))
        let synthetic = checkpoint.syntheticMessages.map { $0.toMessage() }
        return (synthetic + tail, true)
    }

    /// Builds the persisted DTO list for a checkpoint:
    /// - `.summarized` strips tool-call metadata (synthesized text has no underlying tool call).
    /// - `.pruned` preserves `toolCalls` and `toolCallId` so the rehydrated messages remain valid
    ///   agent-loop messages on reuse.
    static func syntheticMessagesForPersistence(
        from compactedMiddle: [Message],
        kind: ContextCompactionCheckpointKind
    ) -> [ContextCompactionMessageDTO] {
        switch kind {
        case .summarized:
            return compactedMiddle.map { ContextCompactionMessageDTO(message: $0) }
        case .pruned:
            return compactedMiddle.map { ContextCompactionMessageDTO.prunedDTO(from: $0) }
        }
    }

    /// Fans out a single summarized summary across covered raw middle messages so checkpoint reuse
    /// satisfies `syntheticMessages.count == coveredMessageIDs.count`.
    static func summarizedSyntheticDTOsForPersistence(
        summaryMessages: [Message],
        coveredRawMiddle: [Message],
        kind: ContextCompactionCheckpointKind
    ) -> [ContextCompactionMessageDTO] {
        guard kind == .summarized,
              summaryMessages.count < coveredRawMiddle.count,
              let summary = summaryMessages.first
        else {
            return syntheticMessagesForPersistence(from: summaryMessages, kind: kind)
        }
        let body = summary.content
        return coveredRawMiddle.map { raw in
            ContextCompactionMessageDTO(
                id: UUID(),
                role: raw.role.rawValue,
                content: body
            )
        }
    }

    /// Gates before invoking the compaction LLM (does not apply when transform is disabled or phase non-initial — caller checks those).
    static func shouldRunCompactionLLM(
        rawMiddle: [Message],
        config: ContextCompactionConfiguration,
        conversationID: UUID,
        lastLLMDateByConversationID: [UUID: Date]
    ) -> Bool {
        let chars = estimatedMiddleCharacters(rawMiddle)
        if config.middleMinCharactersForCompactionLLM > 0, chars < config.middleMinCharactersForCompactionLLM {
            return false
        }
        if config.compactionLLMCooldownSeconds > 0,
           let last = lastLLMDateByConversationID[conversationID] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < config.compactionLLMCooldownSeconds {
                return false
            }
        }
        return true
    }
}
