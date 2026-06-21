//
//  Derives harness ``ConversationRunInfo`` rows by walking v2 transcript entries (runs.md segmentation rule).
//  Canonical mapping used here:
//  - run start: opening user input row carrying `transcriptRunID` (opening input trust class informs `kinds`),
//  - run end: terminal assistant row with explicit terminal `finishReason` or terminal custom marker (`run_cancelled` / `run_errored` / `run_bounded`),
//  - open head: active runtime run remains `outcome: open`,
//  - restart reconciliation: stale running heads close with `run_orphaned` semantics.
//

import Foundation
import SwiftAgentKit

private struct RunDerivationMessagePayload: Codable {
    var id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var toolCallId: String?
    var toolCallNames: [String]
    var transcriptRunID: UUID?
    var inputTrustRaw: String?
    var finishReason: String?
}

private struct RunRollupAccumulator {
    private(set) var assistantMessageCount: Int = 0
    private var toolCallNameCounts: [String: Int] = [:]
    private(set) var totalToolCallSlots: Int = 0

    mutating func ingestAssistant(_ payload: RunDerivationMessagePayload) {
        assistantMessageCount += 1
        for raw in payload.toolCallNames {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            toolCallNameCounts[t, default: 0] += 1
            totalToolCallSlots += 1
        }
    }

    mutating func reset() {
        assistantMessageCount = 0
        toolCallNameCounts.removeAll(keepingCapacity: false)
        totalToolCallSlots = 0
    }

    func projectionDetailIfNeeded(_ include: Bool) -> ConversationRunProjectionDetail? {
        guard include else { return nil }
        let totalSlots = totalToolCallSlots
        let rollup: ConversationRunToolRollup?
        if totalSlots > 0 {
            rollup = ConversationRunToolRollup(
                distinctToolNames: toolCallNameCounts.keys.sorted(),
                totalToolCallSlots: totalSlots
            )
        } else {
            rollup = nil
        }
        return ConversationRunProjectionDetail(assistantMessageCount: assistantMessageCount, toolRollup: rollup)
    }
}

private struct RunUsageAccumulator {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var usdCost: Double = 0

    mutating func ingest(_ usage: DelegateCompletionUsagePayload) {
        let prompt = max(0, usage.promptTokens ?? 0)
        let completion = max(0, usage.completionTokens ?? 0)
        let explicitTotal = max(0, usage.totalTokens ?? 0)
        let normalizedTotal = explicitTotal > 0 ? explicitTotal : max(0, prompt + completion)
        let cost = max(0, usage.costUSD ?? 0)
        guard prompt > 0 || completion > 0 || normalizedTotal > 0 || cost > 0 else { return }
        promptTokens += prompt
        completionTokens += completion
        totalTokens += normalizedTotal
        usdCost += cost
    }

    var tokenRollup: ConversationRunTokenRollup? {
        guard promptTokens > 0 || completionTokens > 0 || totalTokens > 0 else { return nil }
        return ConversationRunTokenRollup(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens
        )
    }

    var costRollup: ConversationRunCostRollup? {
        guard usdCost > 0 else { return nil }
        return ConversationRunCostRollup(usd: usdCost)
    }
}

enum TranscriptRunDerivation {
    private struct ConversationRunCursorKey: Codable {
        var startedAtMillis: Int64
        var runID: UUID
    }

    /// Authoritative, replay-safe usage rollups by run id.
    /// Totals are aggregated from persisted `tool_audit_lifecycle_event` rows carrying completion usage.
    static func authoritativeUsageRollupsByRun(events: [CachedConversationEvent]) -> [UUID: (tokens: ConversationRunTokenRollup?, cost: ConversationRunCostRollup?)] {
        var accumulators: [UUID: RunUsageAccumulator] = [:]
        var seenSettledKeys: Set<String> = []
        for event in events where event.kind == ConversationEventKind.toolAuditLifecycleEvent.rawValue {
            guard let audit = ConversationEventCodec.decode(ToolAuditLifecycleEventPayload.self, from: event.payloadJSON),
                  let runID = audit.runID,
                  let usage = audit.usage
            else { continue }
            guard audit.name == .toolCompletionAnnounced || audit.name == .toolCallCompleted else {
                continue
            }

            let dedupeKey: String = {
                if let completionID = audit.completionAnnounceID {
                    return "announce:\(completionID.uuidString.lowercased())"
                }
                if let toolCallID = audit.toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines), !toolCallID.isEmpty {
                    return "toolcall:\(toolCallID)"
                }
                return "event:\(event.eventID)"
            }()
            let scopedKey = "\(runID.uuidString.lowercased())::\(dedupeKey)"
            if seenSettledKeys.contains(scopedKey) { continue }
            seenSettledKeys.insert(scopedKey)
            var accumulator = accumulators[runID] ?? RunUsageAccumulator()
            accumulator.ingest(usage)
            accumulators[runID] = accumulator
        }

        return accumulators.reduce(into: [:]) { partial, element in
            let (runID, accumulator) = element
            partial[runID] = (tokens: accumulator.tokenRollup, cost: accumulator.costRollup)
        }
    }

    /// Run ids that still need a durable `run_orphaned` marker appended (startup repair).
    static func runIDsRequiringOrphanRepair(
        sortedEntries: [SessionTranscriptEntry],
        persistedCurrentRunID: UUID?,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        conversationID: UUID
    ) -> [UUID] {
        let sorted = sortedEntries.sorted { $0.sequence < $1.sequence }
        let rows = deriveConversationRuns(
            sortedEntries: sorted,
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            includeProjectionDetail: false
        )
        return rows
            .filter { row in
                row.outcome == .errored
                    && row.errorDetails?.class == RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue
                    && !transcriptHasOrphanMarker(sortedEntries: sorted, runId: row.id)
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    static func transcriptHasOrphanMarker(sortedEntries: [SessionTranscriptEntry], runId: UUID) -> Bool {
        let sorted = sortedEntries.sorted { $0.sequence < $1.sequence }
        for entry in sorted where entry.type == .custom {
            guard let marker = try? RunLifecycleTranscriptMarkerPayload.decode(from: entry.payloadJSON),
                  marker.customType == RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue,
                  marker.runId == runId
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Implements canonical runs.md segmentation over transcript entries.
    /// Boundaries are derived from opening input (`transcriptRunID`) and terminal assistant/custom closures.
    static func deriveConversationRuns(
        sortedEntries: [SessionTranscriptEntry],
        conversationID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        includeProjectionDetail: Bool = false,
        authoritativeUsageRollupsByRunID: [UUID: (tokens: ConversationRunTokenRollup?, cost: ConversationRunCostRollup?)] = [:]
    ) -> [ConversationRunInfo] {
        let sorted = sortedEntries.sorted { $0.sequence < $1.sequence }

        struct MutableRun {
            let id: UUID
            var startedAt: Date
            var firstMessageId: String
        }

        var finished: [ConversationRunInfo] = []
        var active: MutableRun?
        var rollupAccumulator = RunRollupAccumulator()

        func appendFinished(
            id: UUID,
            startedAt: Date,
            endedAt: Date?,
            outcome: ConversationRunOutcome,
            firstMessageId: String,
            lastMessageId: String?,
            cancellationReason: String?,
            errorDetails: ConversationRunErrorDetails?,
            rollupSnapshot: RunRollupAccumulator
        ) {
            let rollups = authoritativeUsageRollupsByRunID[id]
            finished.append(
                ConversationRunInfo(
                    id: id,
                    conversationID: conversationID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    outcome: outcome,
                    iterationCount: rollupSnapshot.assistantMessageCount,
                    toolCallCount: rollupSnapshot.totalToolCallSlots,
                    firstMessageId: firstMessageId,
                    lastMessageId: lastMessageId,
                    cancellationReason: cancellationReason,
                    errorDetails: errorDetails,
                    tokenRollup: rollups?.tokens,
                    costRollup: rollups?.cost,
                    projectionDetail: rollupSnapshot.projectionDetailIfNeeded(includeProjectionDetail)
                )
            )
        }

        func closePriorOpenIfNeeded(at date: Date, becauseNewUser rid: UUID) {
            guard let a = active, a.id != rid else { return }
            let snap = rollupAccumulator
            appendFinished(
                id: a.id,
                startedAt: a.startedAt,
                endedAt: date,
                outcome: .errored,
                firstMessageId: a.firstMessageId,
                lastMessageId: nil,
                cancellationReason: nil,
                errorDetails: ConversationRunErrorDetails(
                    class: RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue,
                    message: "stale_running_reconciled"
                ),
                rollupSnapshot: snap
            )
            active = nil
            rollupAccumulator.reset()
        }

        for entry in sorted {
            if entry.type == .custom,
               let marker = try? RunLifecycleTranscriptMarkerPayload.decode(from: entry.payloadJSON),
               let kind = RunLifecycleTranscriptMarkerKind(rawValue: marker.customType),
               marker.runId == active?.id {
                switch kind {
                case .run_cancelled:
                    if let a = active {
                        let snap = rollupAccumulator
                        appendFinished(
                            id: a.id,
                            startedAt: a.startedAt,
                            endedAt: entry.timestamp,
                            outcome: .cancelled,
                            firstMessageId: a.firstMessageId,
                            lastMessageId: entry.entryId.rawValue,
                            cancellationReason: marker.reason ?? marker.resolvedTerminalReason()?.detail,
                            errorDetails: nil,
                            rollupSnapshot: snap
                        )
                        active = nil
                        rollupAccumulator.reset()
                    }
                case .run_errored, .run_bounded, .run_orphaned:
                    if let a = active {
                        let snap = rollupAccumulator
                        let outcome: ConversationRunOutcome = (kind == .run_bounded) ? .bounded : .errored
                        let errorDetails: ConversationRunErrorDetails? = {
                            guard outcome == .errored else { return nil }
                            return ConversationRunErrorDetails(
                                class: marker.customType,
                                message: marker.reason ?? marker.resolvedTerminalReason()?.detail ?? marker.customType
                            )
                        }()
                        appendFinished(
                            id: a.id,
                            startedAt: a.startedAt,
                            endedAt: entry.timestamp,
                            outcome: outcome,
                            firstMessageId: a.firstMessageId,
                            lastMessageId: entry.entryId.rawValue,
                            cancellationReason: nil,
                            errorDetails: errorDetails,
                            rollupSnapshot: snap
                        )
                        active = nil
                        rollupAccumulator.reset()
                    }
                }
                continue
            }

            guard entry.type == .message || entry.type == .system else { continue }
            guard let payload = try? decodeMessage(entry.payloadJSON) else { continue }

            if payload.role == MessageRole.user.rawValue,
               let rid = payload.transcriptRunID,
               isOpeningInputTrustClass(payload.inputTrustRaw) {
                closePriorOpenIfNeeded(at: entry.timestamp, becauseNewUser: rid)
                if active?.id != rid {
                    active = MutableRun(id: rid, startedAt: entry.timestamp, firstMessageId: entry.entryId.rawValue)
                    rollupAccumulator.reset()
                }
            }

            guard let current = active else { continue }

            if payload.role == MessageRole.assistant.rawValue {
                let toolNames = payload.toolCallNames.compactMap {
                    let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
                let hasTools = !toolNames.isEmpty
                let rid = payload.transcriptRunID
                if rid != nil && rid != current.id { continue }
                rollupAccumulator.ingestAssistant(payload)
                if !hasTools && isTerminalAssistantFinishReason(payload.finishReason) {
                    let snap = rollupAccumulator
                    appendFinished(
                        id: current.id,
                        startedAt: current.startedAt,
                        endedAt: entry.timestamp,
                        outcome: .completed,
                        firstMessageId: current.firstMessageId,
                        lastMessageId: entry.entryId.rawValue,
                        cancellationReason: nil,
                        errorDetails: nil,
                        rollupSnapshot: snap
                    )
                    active = nil
                    rollupAccumulator.reset()
                }
            }
        }

        if let tail = active {
            let isRuntimeActive = activeRuntimeConversationID == conversationID && activeRuntimeRunID == tail.id
            let snap = rollupAccumulator
            if isRuntimeActive {
                appendFinished(
                    id: tail.id,
                    startedAt: tail.startedAt,
                    endedAt: nil,
                    outcome: .open,
                    firstMessageId: tail.firstMessageId,
                    lastMessageId: nil,
                    cancellationReason: nil,
                    errorDetails: nil,
                    rollupSnapshot: snap
                )
            } else {
                appendFinished(
                    id: tail.id,
                    startedAt: tail.startedAt,
                    endedAt: tail.startedAt,
                    outcome: .errored,
                    firstMessageId: tail.firstMessageId,
                    lastMessageId: nil,
                    cancellationReason: nil,
                    errorDetails: ConversationRunErrorDetails(
                        class: RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue,
                        message: "stale_running_reconciled"
                    ),
                    rollupSnapshot: snap
                )
            }
        }

        return finished.sorted { lhs, rhs in
            let ld = lhs.startedAt ?? lhs.endedAt ?? .distantPast
            let rd = rhs.startedAt ?? rhs.endedAt ?? .distantPast
            if ld == rd { return lhs.id.uuidString > rhs.id.uuidString }
            return ld > rd
        }
    }

    static func listConversationRuns(
        derivedRunsNewestFirst: [ConversationRunInfo],
        sortedEntries: [SessionTranscriptEntry],
        filter: ConversationRunListFilter
    ) -> ConversationRunListResponse {
        let kindByRunID = runKindByRunID(sortedEntries: sortedEntries)
        let outcomes = filter.outcomes.map(Set.init)
        let kinds = filter.kinds.map(Set.init)
        let since = filter.since

        var filtered = derivedRunsNewestFirst.filter { row in
            if let outcomes, !outcomes.contains(row.outcome) {
                return false
            }
            if let since,
               let startedAt = row.startedAt,
               startedAt <= since {
                return false
            } else if since != nil && row.startedAt == nil {
                return false
            }
            if let kinds {
                let kind = kindByRunID[row.id] ?? .live
                if !kinds.contains(kind) { return false }
            }
            return true
        }

        let total = filtered.count
        if let cursor = filter.cursor,
           let cursorKey = decodeCursor(cursor) {
            filtered = filtered.filter { row in
                let rowDate = row.startedAt ?? row.endedAt ?? .distantPast
                let cursorDate = Date(timeIntervalSince1970: TimeInterval(cursorKey.startedAtMillis) / 1000.0)
                if rowDate < cursorDate { return true }
                if rowDate > cursorDate { return false }
                return row.id.uuidString.lowercased() < cursorKey.runID.uuidString.lowercased()
            }
        }

        let page = Array(filtered.prefix(filter.limit))
        let nextCursor: String?
        if page.count < filtered.count, let last = page.last {
            let date = last.startedAt ?? last.endedAt ?? .distantPast
            let key = ConversationRunCursorKey(
                startedAtMillis: Int64((date.timeIntervalSince1970 * 1000.0).rounded()),
                runID: last.id
            )
            nextCursor = encodeCursor(key)
        } else {
            nextCursor = nil
        }

        return ConversationRunListResponse(
            runs: page,
            cursor: nextCursor,
            total: total
        )
    }

    private static func runKindByRunID(sortedEntries: [SessionTranscriptEntry]) -> [UUID: ConversationRunKind] {
        let sorted = sortedEntries.sorted { $0.sequence < $1.sequence }
        var map: [UUID: ConversationRunKind] = [:]
        for entry in sorted where entry.type == .message || entry.type == .system {
            guard let payload = try? decodeMessage(entry.payloadJSON),
                  payload.role == MessageRole.user.rawValue,
                  let runID = payload.transcriptRunID,
                  map[runID] == nil
            else { continue }
            map[runID] = runKind(fromInputTrustRaw: payload.inputTrustRaw)
        }
        return map
    }

    private static func runKind(fromInputTrustRaw inputTrustRaw: String?) -> ConversationRunKind {
        let raw = inputTrustRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.contains("delegate") || raw.contains("subagent") || raw.contains("sub-agent") {
            return .delegate
        }
        if raw.contains("channel") {
            return .channel
        }
        if raw.contains("trigger") || raw.contains("automation") || raw.contains("webhook") {
            return .trigger
        }
        return .live
    }

    private static func isOpeningInputTrustClass(_ inputTrustRaw: String?) -> Bool {
        let raw = inputTrustRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty { return true } // Default direct API caller trust class is user.
        if raw.contains("owner") || raw.contains("user") || raw.contains("direct_user_entry") { return true }
        if raw.contains("channel") { return true }
        if raw.contains("trigger") || raw.contains("automation") { return true }
        if raw.contains("delegate") || raw.contains("subagent") || raw.contains("sub-agent") { return true }
        return false
    }

    private static func isTerminalAssistantFinishReason(_ finishReason: String?) -> Bool {
        guard let raw = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        return raw == "stop" || raw == "end_turn" || raw == "max_tokens" || raw == "length"
    }

    private static func encodeCursor(_ key: ConversationRunCursorKey) -> String? {
        guard let data = try? JSONEncoder().encode(key) else { return nil }
        return data.base64EncodedString()
    }

    private static func decodeCursor(_ encoded: String) -> ConversationRunCursorKey? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(ConversationRunCursorKey.self, from: data)
    }

    private static func decodeMessage(_ payloadJSON: String) throws -> RunDerivationMessagePayload {
        let wire = try MessageTranscriptPayloadCodec.decode(payloadJSON)
        return RunDerivationMessagePayload(
            id: wire.id,
            role: wire.role,
            content: wire.content,
            timestamp: wire.timestamp,
            toolCallId: wire.toolCallId,
            toolCallNames: wire.resolvedToolCallNames(),
            transcriptRunID: wire.transcriptRunID,
            inputTrustRaw: wire.inputTrustRaw,
            finishReason: wire.finishReason
        )
    }
}
