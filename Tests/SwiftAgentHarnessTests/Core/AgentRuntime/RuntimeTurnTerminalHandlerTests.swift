import Foundation
import Testing
@testable import SwiftAgentHarness

private actor RuntimeTurnTerminalCapture {
    private(set) var pendingReasons: [(conversationID: UUID, runID: UUID, reason: ConversationRunTerminalReason?)] = []
    private(set) var stripped: [(conversationID: UUID, anchorID: UUID)] = []
    private(set) var cancelledConversationIDs: [UUID] = []
    private(set) var failures: [String] = []
    private(set) var infoLogs: [String] = []
    private(set) var errorLogs: [String] = []

    func setPendingReason(conversationID: UUID, runID: UUID, reason: ConversationRunTerminalReason?) {
        pendingReasons.append((conversationID, runID, reason))
    }

    func appendStripped(conversationID: UUID, anchorID: UUID) {
        stripped.append((conversationID, anchorID))
    }

    func appendCancelled(_ conversationID: UUID) {
        cancelledConversationIDs.append(conversationID)
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
            stripRunTailAfterAnchorIfNeeded: { cid, aid in await capture.appendStripped(conversationID: cid, anchorID: aid) },
            applyStreamingUserCancellation: { cid in await capture.appendCancelled(cid) },
            applySendFailure: { error in await capture.appendFailure(error.localizedDescription) },
            logInfo: { message in await capture.appendInfo(message) },
            logError: { message in await capture.appendError(message) }
        )

        #expect(terminal.status == .cancelled)
        #expect(terminal.markerKind == RuntimeTurnTerminalHandler.runCancelledMarkerKind)
        let stripped = await capture.stripped
        #expect(stripped.count == 1)
        #expect(stripped.first?.conversationID == conversationID)
        #expect(stripped.first?.anchorID == anchorID)
        #expect((await capture.cancelledConversationIDs).contains(conversationID))
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
            stripRunTailAfterAnchorIfNeeded: { _, _ in await capture.appendStripped(conversationID: UUID(), anchorID: UUID()) },
            applyStreamingUserCancellation: { cid in await capture.appendCancelled(cid) },
            applySendFailure: { error in await capture.appendFailure(error.localizedDescription) },
            logInfo: { message in await capture.appendInfo(message) },
            logError: { message in await capture.appendError(message) }
        )

        #expect(terminal.status == .failed)
        #expect(terminal.markerKind == nil)
        #expect((await capture.failures).count == 1)
        #expect(await capture.cancelledConversationIDs.isEmpty)
    }
}

