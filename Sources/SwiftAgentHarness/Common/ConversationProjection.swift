import Foundation
import SwiftAgentKit

// Unified **UI** projection over the merged conversation event log.
// Model-bound projection for the LLM/orchestrator lives in `ContextEngine/`.

enum ConversationProjection {
    struct ProjectionMetrics: Sendable {
        let causalityRejectedSummaryCount: Int
        let overlapConflictResolvedCount: Int
        let decodeRejectedSummaryCount: Int
        let invalidStructuralSummaryCount: Int
        let unsuccessfulSummarySkippedCount: Int
        let deduplicatedSummaryEventCount: Int
    }

    private struct SummaryEnvelope {
        let eventID: Int
        let payload: SummaryCreatedEventPayload
    }

    /// - Parameters:
    ///   - frontierEventID: Causal upper bound for `basedOnEventID` checks. Pass `nil` to use `max(events.map(\.eventID))` (requires a complete event batch for correct causality).
    static func projectMessagesWithMetrics(
        baseMessages: [Message],
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil
    ) -> (messages: [Message], metrics: ProjectionMetrics, frontierEventID: Int) {
        let frontier = frontierEventID ?? (events.map(\.eventID).max() ?? 0)
        let emptyMetrics = ProjectionMetrics(
            causalityRejectedSummaryCount: 0,
            overlapConflictResolvedCount: 0,
            decodeRejectedSummaryCount: 0,
            invalidStructuralSummaryCount: 0,
            unsuccessfulSummarySkippedCount: 0,
            deduplicatedSummaryEventCount: 0
        )
        guard !baseMessages.isEmpty else {
            return ([], emptyMetrics, frontier)
        }

        let baseIDs = Set(baseMessages.map(\.id))
        var decodeRejected = 0
        var invalidStructural = 0
        var unsuccessful = 0
        var causalityRejected = 0

        let turnSummaryInvalidationFloor = ContextCompactionCheckpointSupport.derivedInvalidationFloor(
            events: events,
            invalidatedKindKeys: [HarnessCheckpointInvalidationKind.turnSummaryEvent]
        )

        var rawEnvelopes: [SummaryEnvelope] = []
        for event in events where event.kind == ConversationEventKind.turnSummaryEvent.rawValue {
            if event.eventID <= turnSummaryInvalidationFloor {
                causalityRejected += 1
                continue
            }
            guard let payload = ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: event.payloadJSON) else {
                decodeRejected += 1
                continue
            }
            guard payload.succeeded else {
                unsuccessful += 1
                continue
            }
            guard payload.startEventID <= payload.endEventID,
                  !payload.coveredMessageIDs.isEmpty,
                  payload.basedOnEventID <= frontier else {
                causalityRejected += 1
                continue
            }
            let coveredSet = Set(payload.coveredMessageIDs)
            guard coveredSet.isSubset(of: baseIDs) else {
                invalidStructural += 1
                continue
            }
            guard let expectedFirst = firstCoveredInBaseOrder(baseMessages: baseMessages, covered: coveredSet),
                  expectedFirst == payload.firstCoveredMessageID else {
                invalidStructural += 1
                continue
            }
            rawEnvelopes.append(SummaryEnvelope(eventID: event.eventID, payload: payload))
        }

        let (dedupedEnvelopes, dedupeCount) = dedupeSummaryEnvelopes(rawEnvelopes)

        let sorted = dedupedEnvelopes.sorted { lhs, rhs in
            if lhs.eventID != rhs.eventID {
                return lhs.eventID > rhs.eventID
            }
            if lhs.payload.coveredMessageIDs.count != rhs.payload.coveredMessageIDs.count {
                return lhs.payload.coveredMessageIDs.count > rhs.payload.coveredMessageIDs.count
            }
            return lhs.payload.createdAt > rhs.payload.createdAt
        }

        var overlapConflictResolvedCount = 0
        var selected: [SummaryEnvelope] = []
        var covered = Set<UUID>()
        for envelope in sorted {
            let ids = Set(envelope.payload.coveredMessageIDs)
            if ids.isDisjoint(with: covered) {
                selected.append(envelope)
                covered.formUnion(ids)
            } else {
                overlapConflictResolvedCount += 1
            }
        }

        let summaries = selected.map(\.payload)
        guard !summaries.isEmpty else {
            return (
                baseMessages,
                ProjectionMetrics(
                    causalityRejectedSummaryCount: causalityRejected,
                    overlapConflictResolvedCount: overlapConflictResolvedCount,
                    decodeRejectedSummaryCount: decodeRejected,
                    invalidStructuralSummaryCount: invalidStructural,
                    unsuccessfulSummarySkippedCount: unsuccessful,
                    deduplicatedSummaryEventCount: dedupeCount
                ),
                frontier
            )
        }

        var hiddenMessageIDs = Set<UUID>()
        for summary in summaries {
            hiddenMessageIDs.formUnion(summary.coveredMessageIDs)
        }

        var byFirstCovered: [UUID: SummaryCreatedEventPayload] = [:]
        for summary in summaries {
            guard let first = summary.firstCoveredMessageID else { continue }
            byFirstCovered[first] = summary
        }

        var output: [Message] = []
        var emittedSummaryIDs = Set<UUID>()
        for message in baseMessages {
            if let summary = byFirstCovered[message.id],
               !emittedSummaryIDs.contains(summary.summaryMessageID) {
                output.append(
                    Message(
                        id: summary.summaryMessageID,
                        role: .assistant,
                        content: summary.summaryContent,
                        timestamp: summary.createdAt,
                        toolCalls: []
                    )
                )
                emittedSummaryIDs.insert(summary.summaryMessageID)
            }
            if hiddenMessageIDs.contains(message.id) {
                continue
            }
            output.append(message)
        }

        return (
            output,
            ProjectionMetrics(
                causalityRejectedSummaryCount: causalityRejected,
                overlapConflictResolvedCount: overlapConflictResolvedCount,
                decodeRejectedSummaryCount: decodeRejected,
                invalidStructuralSummaryCount: invalidStructural,
                unsuccessfulSummarySkippedCount: unsuccessful,
                deduplicatedSummaryEventCount: dedupeCount
            ),
            frontier
        )
    }

    static func projectMessages(
        baseMessages: [Message],
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil
    ) -> [Message] {
        projectMessagesWithMetrics(baseMessages: baseMessages, events: events, frontierEventID: frontierEventID).messages
    }

    private static func firstCoveredInBaseOrder(baseMessages: [Message], covered: Set<UUID>) -> UUID? {
        for message in baseMessages where covered.contains(message.id) {
            return message.id
        }
        return nil
    }

    /// Keeps the newest `eventID` per `summaryMessageID`.
    private static func dedupeSummaryEnvelopes(_ envelopes: [SummaryEnvelope]) -> (deduped: [SummaryEnvelope], duplicateCount: Int) {
        var bestBySummaryID: [UUID: SummaryEnvelope] = [:]
        var duplicateCount = 0
        for envelope in envelopes {
            let sid = envelope.payload.summaryMessageID
            if let existing = bestBySummaryID[sid] {
                duplicateCount += 1
                if envelope.eventID > existing.eventID {
                    bestBySummaryID[sid] = envelope
                }
            } else {
                bestBySummaryID[sid] = envelope
            }
        }
        return (Array(bestBySummaryID.values), duplicateCount)
    }
}
