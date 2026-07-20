import Foundation
import SwiftAgentKit
import Testing

@testable import SwiftAgentHarness

private struct DerivationTestMessagePayload: Codable {
    var id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var toolCallId: String?
    var toolCallNames: [String]
    var transcriptRunID: UUID?
    var inputTrustRaw: String?
    var finishReason: String?

    static func json(
        role: MessageRole,
        transcriptRunID: UUID?,
        toolCallNames: [String] = [],
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        inputTrustRaw: String? = nil,
        finishReason: String? = nil
    ) throws -> String {
        let p = DerivationTestMessagePayload(
            id: UUID(),
            role: role.rawValue,
            content: "",
            timestamp: timestamp,
            toolCallId: nil,
            toolCallNames: toolCallNames,
            transcriptRunID: transcriptRunID,
            inputTrustRaw: inputTrustRaw ?? (role == .user ? "user" : nil),
            finishReason: finishReason
        )
        return try String(decoding: JSONEncoder().encode(p), as: UTF8.self)
    }
}

@Suite("Transcript run derivation")
struct TranscriptRunDerivationTests {

    @Test("Terminal assistant closure exposes projectionDetail rollups when requested")
    func projectionDetailForTerminalAssistantClosure() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    toolCallNames: ["alpha", "beta"],
                    timestamp: base.addingTimeInterval(1)
                )
            ),
            SessionTranscriptEntry(
                sequence: 3,
                entryId: .generate(),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    timestamp: base.addingTimeInterval(2),
                    finishReason: "stop"
                )
            ),
        ]
        let slim = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil,
            includeProjectionDetail: false
        )
        let rich = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil,
            includeProjectionDetail: true
        )
        #expect(slim.count == 1)
        #expect(slim[0].projectionDetail == nil)

        #expect(rich.count == 1)
        let detail = try #require(rich[0].projectionDetail)
        #expect(detail.assistantMessageCount == 2)
        let rollup = try #require(detail.toolRollup)
        #expect(rollup.distinctToolNames == ["alpha", "beta"])
        #expect(rollup.totalToolCallSlots == 2)
    }

    @Test("ConversationRunInfo JSON round-trip preserves canonical fields and projectionDetail")
    func conversationRunInfoCodableRoundTrip() throws {
        let cid = UUID()
        let rid = UUID()
        let row = ConversationRunInfo(
            id: rid,
            conversationID: cid,
            startedAt: Date(timeIntervalSince1970: 2),
            endedAt: Date(timeIntervalSince1970: 3),
            outcome: .bounded,
            iterationCount: 1,
            toolCallCount: 1,
            firstMessageId: "deadbeef",
            lastMessageId: "feedface",
            terminalReason: ConversationRunTerminalReason(
                category: .boundedStop,
                boundedReason: .maxAgentIterations,
                detail: "hit_guardrail"
            ),
            tokenRollup: ConversationRunTokenRollup(promptTokens: 12, completionTokens: 8, totalTokens: 20),
            costRollup: ConversationRunCostRollup(usd: 0.015),
            projectionDetail: ConversationRunProjectionDetail(
                assistantMessageCount: 1,
                toolRollup: ConversationRunToolRollup(distinctToolNames: ["t"], totalToolCallSlots: 1)
            )
        )
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(ConversationRunInfo.self, from: data)
        #expect(decoded == row)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "terminalReason")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ConversationRunInfo.self, from: stripped)
        #expect(legacy.terminalReason == nil)
        #expect(legacy.outcome == .bounded)
        #expect(legacy.id == rid)
    }

    @Test("Authoritative usage rollups dedupe repeated completion lifecycle rows")
    func authoritativeUsageRollupsDeduplicateCompletionSignals() throws {
        let conversationID = UUID()
        let runID = UUID()
        let announceID = UUID()
        let usage = DelegateCompletionUsagePayload(promptTokens: 10, completionTokens: 5, totalTokens: 15, costUSD: 0.02)
        let started = ToolAuditLifecycleEventPayload(
            name: .toolCallCompleted,
            runID: runID,
            iteration: 1,
            modelID: nil,
            toolName: "web_search",
            delegateHandleID: nil,
            toolCallID: "tc_1",
            completionAnnounceID: announceID,
            usage: usage,
            approvalState: nil,
            policyReason: nil,
            approvalSource: nil,
            approvalReason: nil,
            argumentDigest: nil,
            argumentByteCount: nil,
            argumentRedaction: nil,
            resultDigest: nil,
            resultByteCount: nil,
            resultRedaction: nil,
            resultTruncated: nil,
            executionEnvironmentKind: nil,
            executionEnvironmentAdapterID: nil,
            executionIsolationLevel: nil,
            source: "test",
            createdAt: Date()
        )
        let completed = ToolAuditLifecycleEventPayload(
            name: .toolCompletionAnnounced,
            runID: runID,
            iteration: 1,
            modelID: nil,
            toolName: "web_search",
            delegateHandleID: nil,
            toolCallID: "tc_1",
            completionAnnounceID: announceID,
            usage: usage,
            approvalState: nil,
            policyReason: nil,
            approvalSource: nil,
            approvalReason: nil,
            argumentDigest: nil,
            argumentByteCount: nil,
            argumentRedaction: nil,
            resultDigest: nil,
            resultByteCount: nil,
            resultRedaction: nil,
            resultTruncated: nil,
            executionEnvironmentKind: nil,
            executionEnvironmentAdapterID: nil,
            executionIsolationLevel: nil,
            source: "test",
            createdAt: Date()
        )
        let events: [CachedConversationEvent] = [
            CachedConversationEvent(
                conversationID: conversationID,
                eventID: 1,
                kind: ConversationEventKind.toolAuditLifecycleEvent.rawValue,
                payloadJSON: ConversationEventCodec.encode(started)
            ),
            CachedConversationEvent(
                conversationID: conversationID,
                eventID: 2,
                kind: ConversationEventKind.toolAuditLifecycleEvent.rawValue,
                payloadJSON: ConversationEventCodec.encode(completed)
            ),
        ]
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(events: events)
        let row = try #require(rollups[runID])
        #expect(row.tokens?.promptTokens == 10)
        #expect(row.tokens?.completionTokens == 5)
        #expect(row.tokens?.totalTokens == 15)
        #expect(row.cost?.usd == 0.02)
    }

    @Test("Terminal run_cancelled marker closes run with canonical cancelled outcome")
    func cancelledOutcomeDerivation() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_010)
        let userEntryID = SessionEntryID(rawValue: "aa11aa11")
        let cancelledEntryID = SessionEntryID(rawValue: "bb22bb22")
        let markerPayload = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_cancelled,
            runId: runID,
            reason: "user_stop_requested",
            createdAt: base.addingTimeInterval(1)
        ).encodedJSONString()
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: userEntryID,
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: cancelledEntryID,
                parentEntryId: userEntryID,
                type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_cancelled.rawValue,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: markerPayload
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let run = try #require(runs.first)
        #expect(run.outcome == .cancelled)
        #expect(run.cancellationReason == "user_stop_requested")
        #expect(run.terminalReason == ConversationRunTerminalReason(
            category: .externalCancellation,
            detail: "user_stop_requested"
        ))
        #expect(run.firstMessageId == userEntryID.rawValue)
        #expect(run.lastMessageId == cancelledEntryID.rawValue)
    }

    @Test("Terminal run_errored and run_bounded markers map to canonical outcomes")
    func erroredAndBoundedOutcomeDerivation() throws {
        let cid = UUID()
        let erroredRunID = UUID()
        let boundedRunID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_020)

        let erroredMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_errored,
            runId: erroredRunID,
            reason: "delegate_failed",
            createdAt: base.addingTimeInterval(1)
        ).encodedJSONString()
        let boundedMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_bounded,
            runId: boundedRunID,
            reason: "max_iterations",
            createdAt: base.addingTimeInterval(3)
        ).encodedJSONString()

        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "cc33cc33"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: erroredRunID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2, entryId: SessionEntryID(rawValue: "dd44dd44"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_errored.rawValue, timestamp: base.addingTimeInterval(1), payloadJSON: erroredMarker
            ),
            SessionTranscriptEntry(
                sequence: 3, entryId: SessionEntryID(rawValue: "ee55ee55"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: boundedRunID, timestamp: base.addingTimeInterval(2))
            ),
            SessionTranscriptEntry(
                sequence: 4, entryId: SessionEntryID(rawValue: "ff66ff66"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_bounded.rawValue, timestamp: base.addingTimeInterval(3), payloadJSON: boundedMarker
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let errored = try #require(runs.first(where: { $0.id == erroredRunID }))
        #expect(errored.outcome == .errored)
        #expect(errored.errorDetails?.class == "run_errored")
        #expect(errored.errorDetails?.message == "delegate_failed")
        #expect(errored.terminalReason == ConversationRunTerminalReason(
            category: .failure,
            detail: "delegate_failed"
        ))
        let bounded = try #require(runs.first(where: { $0.id == boundedRunID }))
        #expect(bounded.outcome == .bounded)
        #expect(bounded.errorDetails == nil)
        #expect(bounded.terminalReason == ConversationRunTerminalReason(
            category: .boundedStop,
            detail: "max_iterations"
        ))
    }

    @Test("Structured terminalReason fields enrich but never re-categorize boundary kind")
    func structuredTerminalReasonDoesNotRecategorizeBoundary() throws {
        let cid = UUID()
        let cancelledRunID = UUID()
        let boundedRunID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_025)

        let cancelledMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_cancelled,
            runId: cancelledRunID,
            reason: "budget",
            createdAt: base.addingTimeInterval(1),
            terminalReason: ConversationRunTerminalReason(
                category: .boundedStop,
                boundedReason: .maxAgentIterations,
                detail: "stored_conflict"
            )
        ).encodedJSONString()
        let boundedMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_bounded,
            runId: boundedRunID,
            createdAt: base.addingTimeInterval(3),
            terminalReason: ConversationRunTerminalReason(
                category: .failure,
                boundedReason: .maxAgentIterations,
                detail: "guardrail"
            )
        ).encodedJSONString()

        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "a1a1a1a1"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: cancelledRunID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2, entryId: SessionEntryID(rawValue: "b2b2b2b2"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_cancelled.rawValue,
                timestamp: base.addingTimeInterval(1), payloadJSON: cancelledMarker
            ),
            SessionTranscriptEntry(
                sequence: 3, entryId: SessionEntryID(rawValue: "c3c3c3c3"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: boundedRunID, timestamp: base.addingTimeInterval(2)
                )
            ),
            SessionTranscriptEntry(
                sequence: 4, entryId: SessionEntryID(rawValue: "d4d4d4d4"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_bounded.rawValue,
                timestamp: base.addingTimeInterval(3), payloadJSON: boundedMarker
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let cancelled = try #require(runs.first(where: { $0.id == cancelledRunID }))
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.terminalReason == ConversationRunTerminalReason(
            category: .externalCancellation,
            detail: "stored_conflict"
        ))
        let bounded = try #require(runs.first(where: { $0.id == boundedRunID }))
        #expect(bounded.outcome == .bounded)
        #expect(bounded.terminalReason == ConversationRunTerminalReason(
            category: .boundedStop,
            boundedReason: .maxAgentIterations,
            detail: "guardrail"
        ))
    }

    @Test("Legacy and malformed marker terminal fields still project boundary-authoritative reasons")
    func legacyAndMalformedMarkerTerminalReasonFallbacks() throws {
        let cid = UUID()
        let cancelledRunID = UUID()
        let boundedKnownRunID = UUID()
        let boundedUnknownRunID = UUID()
        let erroredRunID = UUID()
        let orphanedRunID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_027)

        func markerEntry(
            sequence: Int,
            entryId: String,
            kind: RunLifecycleTranscriptMarkerKind,
            runId: UUID,
            reason: String?,
            timestamp: Date,
            categoryOverride: String? = nil,
            boundedOverride: String? = nil
        ) throws -> SessionTranscriptEntry {
            var payload = RunLifecycleTranscriptMarkerPayload(
                kind: kind,
                runId: runId,
                reason: reason,
                createdAt: timestamp
            )
            payload.terminalReasonCategory = categoryOverride
            payload.terminalReasonBounded = boundedOverride
            return SessionTranscriptEntry(
                sequence: sequence,
                entryId: SessionEntryID(rawValue: entryId),
                parentEntryId: nil,
                type: .custom,
                harnessTypeRaw: kind.rawValue,
                timestamp: timestamp,
                payloadJSON: try payload.encodedJSONString()
            )
        }

        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "e1e1e1e1"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: cancelledRunID, timestamp: base)
            ),
            try markerEntry(
                sequence: 2, entryId: "e2e2e2e2", kind: .run_cancelled, runId: cancelledRunID,
                reason: "parent-cancel", timestamp: base.addingTimeInterval(1), categoryOverride: "not-a-category"
            ),
            SessionTranscriptEntry(
                sequence: 3, entryId: SessionEntryID(rawValue: "e3e3e3e3"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: boundedKnownRunID, timestamp: base.addingTimeInterval(2)
                )
            ),
            try markerEntry(
                sequence: 4, entryId: "e4e4e4e4", kind: .run_bounded, runId: boundedKnownRunID,
                reason: ConversationRunBoundedReason.maxAgentIterations.rawValue,
                timestamp: base.addingTimeInterval(3),
                boundedOverride: "not-a-bounded-reason"
            ),
            SessionTranscriptEntry(
                sequence: 5, entryId: SessionEntryID(rawValue: "e5e5e5e5"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(4),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: boundedUnknownRunID, timestamp: base.addingTimeInterval(4)
                )
            ),
            try markerEntry(
                sequence: 6, entryId: "e6e6e6e6", kind: .run_bounded, runId: boundedUnknownRunID,
                reason: "context_budget", timestamp: base.addingTimeInterval(5)
            ),
            SessionTranscriptEntry(
                sequence: 7, entryId: SessionEntryID(rawValue: "e7e7e7e7"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(6),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: erroredRunID, timestamp: base.addingTimeInterval(6)
                )
            ),
            try markerEntry(
                sequence: 8, entryId: "e8e8e8e8", kind: .run_errored, runId: erroredRunID,
                reason: nil, timestamp: base.addingTimeInterval(7)
            ),
            SessionTranscriptEntry(
                sequence: 9, entryId: SessionEntryID(rawValue: "e9e9e9e9"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(8),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: orphanedRunID, timestamp: base.addingTimeInterval(8)
                )
            ),
            try markerEntry(
                sequence: 10, entryId: "eaeaeaea", kind: .run_orphaned, runId: orphanedRunID,
                reason: "stale_running_reconciled", timestamp: base.addingTimeInterval(9)
            ),
        ]

        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        #expect(runs.first(where: { $0.id == cancelledRunID })?.terminalReason == ConversationRunTerminalReason(
            category: .externalCancellation,
            detail: "parent-cancel"
        ))
        #expect(runs.first(where: { $0.id == boundedKnownRunID })?.terminalReason == ConversationRunTerminalReason(
            category: .boundedStop,
            boundedReason: .maxAgentIterations
        ))
        #expect(runs.first(where: { $0.id == boundedUnknownRunID })?.terminalReason == ConversationRunTerminalReason(
            category: .boundedStop,
            detail: "context_budget"
        ))
        #expect(runs.first(where: { $0.id == erroredRunID })?.terminalReason == ConversationRunTerminalReason(
            category: .failure,
            detail: "run_errored"
        ))
        #expect(runs.first(where: { $0.id == orphanedRunID })?.terminalReason == ConversationRunTerminalReason(
            category: .failure,
            detail: "stale_running_reconciled"
        ))
    }

    @Test("Natural assistant completion and open heads omit terminalReason")
    func naturalCompletionAndOpenOmitTerminalReason() throws {
        let cid = UUID()
        let completedRunID = UUID()
        let openRunID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_028)
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "f1f1f1f1"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: completedRunID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2, entryId: SessionEntryID(rawValue: "f2f2f2f2"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant, transcriptRunID: completedRunID,
                    timestamp: base.addingTimeInterval(1), finishReason: "stop"
                )
            ),
            SessionTranscriptEntry(
                sequence: 3, entryId: SessionEntryID(rawValue: "f3f3f3f3"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: openRunID, timestamp: base.addingTimeInterval(2)
                )
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: openRunID,
            activeRuntimeConversationID: cid
        )
        let completed = try #require(runs.first(where: { $0.id == completedRunID }))
        #expect(completed.outcome == .completed)
        #expect(completed.terminalReason == nil)
        let open = try #require(runs.first(where: { $0.id == openRunID }))
        #expect(open.outcome == .open)
        #expect(open.terminalReason == nil)
    }

    @Test("Synthesized orphan reconciliation projects failure before durable marker exists")
    func synthesizedOrphanProjectsFailureTerminalReason() throws {
        let cid = UUID()
        let staleRunID = UUID()
        let nextRunID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_029)
        let beforeMarker: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "01010101"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: staleRunID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2, entryId: SessionEntryID(rawValue: "02020202"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user, transcriptRunID: nextRunID, timestamp: base.addingTimeInterval(1)
                )
            ),
        ]
        let before = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: beforeMarker,
            conversationID: cid,
            activeRuntimeRunID: nextRunID,
            activeRuntimeConversationID: cid
        )
        let staleBefore = try #require(before.first(where: { $0.id == staleRunID }))
        #expect(staleBefore.outcome == .errored)
        #expect(staleBefore.errorDetails?.class == "run_orphaned")
        #expect(staleBefore.terminalReason == ConversationRunTerminalReason(
            category: .failure,
            detail: "stale_running_reconciled"
        ))

        let orphanMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_orphaned,
            runId: staleRunID,
            reason: "stale_running_reconciled",
            createdAt: base.addingTimeInterval(0.5),
            terminalReason: ConversationRunTerminalReason(
                category: .failure,
                detail: "stale_running_reconciled"
            )
        ).encodedJSONString()
        let afterMarker = beforeMarker + [
            SessionTranscriptEntry(
                sequence: 3, entryId: SessionEntryID(rawValue: "03030303"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue,
                timestamp: base.addingTimeInterval(0.5),
                payloadJSON: orphanMarker
            ),
        ]
        // Marker alone after a later opening input is not re-applied to the already-closed prior run;
        // verify a dedicated orphan-closed segment retains the same projected reason.
        let orphanOnly: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1, entryId: SessionEntryID(rawValue: "11111111"), parentEntryId: nil, type: .message,
                harnessTypeRaw: nil, timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: staleRunID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2, entryId: SessionEntryID(rawValue: "22222222"), parentEntryId: nil, type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: orphanMarker
            ),
        ]
        let after = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: orphanOnly,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let staleAfter = try #require(after.first(where: { $0.id == staleRunID }))
        #expect(staleAfter.terminalReason == ConversationRunTerminalReason(
            category: .failure,
            detail: "stale_running_reconciled"
        ))
        #expect(afterMarker.count == 3)
    }

    @Test("Open head run remains open until terminal assistant or terminal marker")
    func openHeadDerivation() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_030)
        let firstID = SessionEntryID(rawValue: "ab12cd34")
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: firstID,
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: SessionEntryID(rawValue: "bc23de45"),
                parentEntryId: firstID,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    toolCallNames: ["tool_a"],
                    timestamp: base.addingTimeInterval(1)
                )
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: runID,
            activeRuntimeConversationID: cid
        )
        let open = try #require(runs.first)
        #expect(open.outcome == .open)
        #expect(open.endedAt == nil)
        #expect(open.firstMessageId == firstID.rawValue)
        #expect(open.lastMessageId == nil)
    }

    @Test("listRuns filters kinds from opening input trust class and terminal outcomes")
    func listRunsFiltersByKindsAndOutcomes() throws {
        let cid = UUID()
        let runLive = UUID()
        let runTrigger = UUID()
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let cancelledMarker = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_cancelled,
            runId: runTrigger,
            reason: "user_stop_requested",
            createdAt: base.addingTimeInterval(3)
        ).encodedJSONString()
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: SessionEntryID(rawValue: "11111111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runLive, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: SessionEntryID(rawValue: "22222222"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runLive,
                    timestamp: base.addingTimeInterval(1),
                    finishReason: "stop"
                )
            ),
            SessionTranscriptEntry(
                sequence: 3,
                entryId: SessionEntryID(rawValue: "33333333"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user,
                    transcriptRunID: runTrigger,
                    timestamp: base.addingTimeInterval(2),
                    inputTrustRaw: "trigger"
                )
            ),
            SessionTranscriptEntry(
                sequence: 4,
                entryId: SessionEntryID(rawValue: "44444444"),
                parentEntryId: nil,
                type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_cancelled.rawValue,
                timestamp: base.addingTimeInterval(3),
                payloadJSON: cancelledMarker
            ),
        ]
        let derived = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let filtered = TranscriptRunDerivation.listConversationRuns(
            derivedRunsNewestFirst: derived,
            sortedEntries: entries,
            filter: ConversationRunListFilter(
                kinds: [.trigger],
                outcomes: [.cancelled],
                limit: 50
            )
        )
        #expect(filtered.runs.count == 1)
        #expect(filtered.runs.first?.id == runTrigger)
        #expect(filtered.runs.first?.outcome == .cancelled)
    }

    @Test("listRuns applies since and cursor pagination")
    func listRunsSinceAndCursorPagination() throws {
        let cid = UUID()
        let runA = UUID()
        let runB = UUID()
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: SessionEntryID(rawValue: "aaaa1111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runA, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: SessionEntryID(rawValue: "aaaa2222"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runA,
                    timestamp: base.addingTimeInterval(1),
                    finishReason: "stop"
                )
            ),
            SessionTranscriptEntry(
                sequence: 3,
                entryId: SessionEntryID(rawValue: "bbbb1111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(10),
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runB, timestamp: base.addingTimeInterval(10))
            ),
            SessionTranscriptEntry(
                sequence: 4,
                entryId: SessionEntryID(rawValue: "bbbb2222"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(11),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runB,
                    timestamp: base.addingTimeInterval(11),
                    finishReason: "stop"
                )
            ),
        ]
        let derived = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let firstPage = TranscriptRunDerivation.listConversationRuns(
            derivedRunsNewestFirst: derived,
            sortedEntries: entries,
            filter: ConversationRunListFilter(since: base.addingTimeInterval(-1), limit: 1)
        )
        #expect(firstPage.runs.count == 1)
        #expect(firstPage.total == 2)
        let cursor = try #require(firstPage.cursor)
        let secondPage = TranscriptRunDerivation.listConversationRuns(
            derivedRunsNewestFirst: derived,
            sortedEntries: entries,
            filter: ConversationRunListFilter(since: base.addingTimeInterval(-1), limit: 1, cursor: cursor)
        )
        #expect(secondPage.runs.count == 1)
        #expect(secondPage.total == 2)
        #expect(secondPage.runs.first?.id != firstPage.runs.first?.id)
    }

    @Test("Assistant with non-terminal finish reason does not close run until terminal marker")
    func nonTerminalAssistantFinishReasonDoesNotCloseRun() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_035)
        let markerPayload = try RunLifecycleTranscriptMarkerPayload(
            kind: .run_bounded,
            runId: runID,
            reason: "max_iterations",
            createdAt: base.addingTimeInterval(2)
        ).encodedJSONString()
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: SessionEntryID(rawValue: "n1111111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: SessionEntryID(rawValue: "n2222222"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    timestamp: base.addingTimeInterval(1),
                    finishReason: "tool_calls"
                )
            ),
            SessionTranscriptEntry(
                sequence: 3,
                entryId: SessionEntryID(rawValue: "n3333333"),
                parentEntryId: nil,
                type: .custom,
                harnessTypeRaw: RunLifecycleTranscriptMarkerKind.run_bounded.rawValue,
                timestamp: base.addingTimeInterval(2),
                payloadJSON: markerPayload
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        let run = try #require(runs.first)
        #expect(run.outcome == .bounded)
        #expect(run.lastMessageId == "n3333333")
    }

    @Test("Terminal-tool run with intermediate bare assistant stall stays open until explicit stop")
    func terminalToolRunWithIntermediateBareAssistantStaysOpen() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_045)
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: SessionEntryID(rawValue: "s1111111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(role: .user, transcriptRunID: runID, timestamp: base)
            ),
            SessionTranscriptEntry(
                sequence: 2,
                entryId: SessionEntryID(rawValue: "s2222222"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(1),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    timestamp: base.addingTimeInterval(1),
                    finishReason: nil
                )
            ),
            SessionTranscriptEntry(
                sequence: 3,
                entryId: SessionEntryID(rawValue: "s3333333"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(2),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    toolCallNames: ["terminal_tool"],
                    timestamp: base.addingTimeInterval(2),
                    finishReason: "tool_calls"
                )
            ),
            SessionTranscriptEntry(
                sequence: 4,
                entryId: SessionEntryID(rawValue: "s4444444"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base.addingTimeInterval(3),
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .assistant,
                    transcriptRunID: runID,
                    timestamp: base.addingTimeInterval(3),
                    finishReason: "stop"
                )
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.id == runID)
        #expect(run.outcome == .completed)
        #expect(run.iterationCount == 3)
    }

    @Test("Non-opening trust class input does not start a new run segment")
    func nonOpeningTrustClassDoesNotStartRun() throws {
        let cid = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let entries: [SessionTranscriptEntry] = [
            SessionTranscriptEntry(
                sequence: 1,
                entryId: SessionEntryID(rawValue: "p1111111"),
                parentEntryId: nil,
                type: .message,
                harnessTypeRaw: nil,
                timestamp: base,
                payloadJSON: try DerivationTestMessagePayload.json(
                    role: .user,
                    transcriptRunID: runID,
                    timestamp: base,
                    inputTrustRaw: "internal_continuation"
                )
            ),
        ]
        let runs = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: cid,
            activeRuntimeRunID: nil,
            activeRuntimeConversationID: nil
        )
        #expect(runs.isEmpty)
    }
}
