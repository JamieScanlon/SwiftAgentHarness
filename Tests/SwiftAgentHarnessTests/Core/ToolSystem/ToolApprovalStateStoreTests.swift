import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolApprovalStateStore")
struct ToolApprovalStateStoreTests {
    private func makeSpec(timeoutMs: Int = 200) -> ToolApprovalContractSpec {
        ToolApprovalContractSpec(
            title: "Approval",
            description: "desc",
            severity: "info",
            timeoutMs: timeoutMs,
            timeoutBehavior: .autoDeny
        )
    }

    @Test("waitForResolution resumes when approval is granted")
    func waitForResolutionResumesOnApprove() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let toolName = "test_tool"
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                toolName: toolName
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual
        )
        #expect(try await waitTask.value.status == .approved)
    }

    @Test("waitForResolution returns denied-cancelled on task cancellation")
    func waitForResolutionDeniedOnCancellation() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let toolName = "cancel_tool"
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                toolName: toolName
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waitTask.cancel()
        for _ in 0..<20 {
            if let resolved = await store.resolution(
                conversationID: conversationID,
                runID: runID,
                toolName: toolName
            ), resolved.status == .denied {
                #expect(resolved.reason == "denied-cancelled")
                return
            }
            await Task.yield()
        }
        Issue.record("Expected denied-cancelled resolution after cancellation")
    }
}
