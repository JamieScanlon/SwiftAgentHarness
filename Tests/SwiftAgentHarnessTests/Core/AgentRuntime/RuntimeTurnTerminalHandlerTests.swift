import Foundation
import Testing
@testable import SwiftAgentHarness

private actor RuntimeTurnTerminalCapture {
    private(set) var pendingReasons: [(conversationID: UUID, runID: UUID, reason: ConversationRunTerminalReason?)] = []
    private(set) var stripped: [(conversationID: UUID, runID: UUID?, anchorID: UUID)] = []
    private(set) var cancelled: [(conversationID: UUID, runID: UUID?)] = []
    private(set) var failures: [String] = []
    private(set) var infoLogs: [String] = []
    private(set) var errorLogs: [String] = []

    func setPendingReason(conversationID: UUID, runID: UUID, reason: ConversationRunTerminalReason?) {
        pendingReasons.append((conversationID, runID, reason))
    }

    func appendStripped(conversationID: UUID, runID: UUID?, anchorID: UUID) {
        stripped.append((conversationID, runID, anchorID))
    }

    func appendCancelled(conversationID: UUID, runID: UUID?) {
        cancelled.append((conversationID, runID))
    }

    func appendFailure(_ message: String) {
        failures.append(message)
    }

    func appendInfo(_ message: String) {
        infoLogs.append(message)
    }

    func appendError(_ message: String) {
        errorLogs.append(message)
    }
}

@Suite("Runtime turn terminal handler")
struct RuntimeTurnTerminalHandlerTests {
    @Test("cancelled result applies cancellation side effects and marker")
    func cancelledResult() async {
        let capture = RuntimeTurnTerminalCapture()
        let conversationID = UUID()
        let runID = UUID()
        let anchorID = UUID()
        let reason = ConversationRunTerminalReason(category: .externalCancellation, detail: "task_cancelled")
        let result = AgentRuntimeRunResult.cancelled(reason: reason)

        let terminal = await RuntimeTurnTerminalHandler.resolve(
            result: result,
            conversationID: conversationID,
            runID: runID,
            activeAnchorUserMessageID: anchorID,
            setPendingTerminalReason: { cid, rid, reason in await capture.setPendingReason(conversationID: cid, runID: rid, reason: reason) },
            stripRunTailAfterAnchorIfNeeded: { cid, rid, aid in
                await capture.appendStripped(conversationID: cid, runID: rid, anchorID: aid)
            },
            applyStreamingUserCancellation: { cid, rid in
                await capture.appendCancelled(conversationID: cid, runID: rid)
            },
            applySendFailure: { error in await capture.appendFailure(error.localizedDescription) },
            logInfo: { message in await capture.appendInfo(message) },
            logError: { message in await capture.appendError(message) }
        )

        #expect(terminal.status == .cancelled)
        #expect(terminal.markerKind == RuntimeTurnTerminalHandler.runCancelledMarkerKind)
        let stripped = await capture.stripped
        #expect(stripped.count == 1)
        #expect(stripped.first?.conversationID == conversationID)
        #expect(stripped.first?.runID == runID)
        #expect(stripped.first?.anchorID == anchorID)
        let cancelled = await capture.cancelled
        #expect(cancelled.count == 1)
        #expect(cancelled.first?.conversationID == conversationID)
        #expect(cancelled.first?.runID == runID)
        #expect(await capture.failures.isEmpty)
    }

    @Test("failed result applies failure path")
    func failedResult() async {
        let capture = RuntimeTurnTerminalCapture()
        let conversationID = UUID()
        let runID = UUID()
        let policy = AgentRuntimeErrorPolicyOutcome(errorClass: .runtime, handling: .failTurn)
        let result = AgentRuntimeRunResult.failed(policy: policy, error: NSError(domain: "x", code: 1))

        let terminal = await RuntimeTurnTerminalHandler.resolve(
            result: result,
            conversationID: conversationID,
            runID: runID,
            activeAnchorUserMessageID: nil,
            setPendingTerminalReason: { cid, rid, reason in await capture.setPendingReason(conversationID: cid, runID: rid, reason: reason) },
            stripRunTailAfterAnchorIfNeeded: { cid, rid, aid in
                await capture.appendStripped(conversationID: cid, runID: rid, anchorID: aid)
            },
            applyStreamingUserCancellation: { cid, rid in
                await capture.appendCancelled(conversationID: cid, runID: rid)
            },
            applySendFailure: { error in await capture.appendFailure(error.localizedDescription) },
            logInfo: { message in await capture.appendInfo(message) },
            logError: { message in await capture.appendError(message) }
        )

        #expect(terminal.status == .failed)
        #expect(terminal.markerKind == nil)
        #expect((await capture.failures).count == 1)
        #expect(await capture.cancelled.isEmpty)
    }
}
