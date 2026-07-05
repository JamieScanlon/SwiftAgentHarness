import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolApprovalStateStore")
struct ToolApprovalStateStoreTests {
    private func makeSpec(
        timeoutMs: Int? = 200,
        timeoutBehavior: ToolPolicyConfiguration.ApprovalTimeoutBehavior = .autoDeny
    ) -> ToolApprovalContractSpec {
        ToolApprovalContractSpec(
            title: "Approval",
            description: "desc",
            severity: "info",
            timeoutMs: timeoutMs,
            timeoutBehavior: timeoutBehavior
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

    @Test("disabled timeout waits indefinitely and resolves only on decision")
    func disabledTimeoutWaitsForResolution() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let toolName = "no_timeout_tool"
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            spec: makeSpec(timeoutMs: nil)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                toolName: toolName
            )
        }
        // Well past any finite default; must still be pending (no auto-resolve).
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = await store.resolution(conversationID: conversationID, runID: runID, toolName: toolName)
        #expect(pending?.status == .pending)
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

    @Test("disabled timeout still resolves denied-cancelled on cancellation")
    func disabledTimeoutCancellation() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let toolName = "no_timeout_cancel_tool"
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            spec: makeSpec(timeoutMs: nil)
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

    @Test("consumeTimedOutApprovals scoped to conversation run leaves other conversations pending")
    func consumeTimedOutApprovalsScopedByConversationRun() async {
        let store = ToolApprovalStateStore()
        let conversationA = UUID()
        let runA = UUID()
        let conversationB = UUID()
        let runB = UUID()
        let past = Date().addingTimeInterval(-10)
        _ = await store.registerPendingApproval(
            conversationID: conversationA,
            runID: runA,
            toolName: "tool_a",
            requestedAt: past,
            spec: makeSpec(timeoutMs: 1000)
        )
        _ = await store.registerPendingApproval(
            conversationID: conversationB,
            runID: runB,
            toolName: "tool_b",
            requestedAt: past,
            spec: makeSpec(timeoutMs: 1000)
        )

        let expiredA = await store.consumeTimedOutApprovals(
            conversationID: conversationA,
            runID: runA
        )
        #expect(expiredA.count == 1)
        #expect(expiredA.first?.toolName == "tool_a")
        #expect(expiredA.first?.conversationID == conversationA)
        #expect(expiredA.first?.runID == runA)

        let resolutionA = await store.resolution(
            conversationID: conversationA,
            runID: runA,
            toolName: "tool_a"
        )
        #expect(resolutionA?.status == .denied)
        #expect(resolutionA?.kind == .timeoutDefault)

        let resolutionB = await store.resolution(
            conversationID: conversationB,
            runID: runB,
            toolName: "tool_b"
        )
        #expect(resolutionB?.status == .pending)

        let expiredB = await store.consumeTimedOutApprovals(
            conversationID: conversationB,
            runID: runB
        )
        #expect(expiredB.count == 1)
        #expect(expiredB.first?.toolName == "tool_b")
        let resolvedB = await store.resolution(
            conversationID: conversationB,
            runID: runB,
            toolName: "tool_b"
        )
        #expect(resolvedB?.status == .denied)
        #expect(resolvedB?.kind == .timeoutDefault)
    }

    @Test("finite timeout still auto-denies after the configured window")
    func finiteTimeoutAutoDenies() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let toolName = "finite_timeout_tool"
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            spec: makeSpec(timeoutMs: 20)
        )
        let resolution = try await store.waitForResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName
        )
        #expect(resolution.status == .denied)
        #expect(resolution.kind == .timeoutDefault)
    }
}
