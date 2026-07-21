import EasyJSON
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

    private func binding(_ toolName: String, args: JSON = .object([:])) -> ToolCallApprovalBinding {
        ToolCallApprovalBinding.from(toolName: toolName, arguments: args)
    }

    @Test("registerPendingApproval records toolCallId for later rewrite")
    func recordsToolCallId() async {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let callBinding = binding("exit_plan_mode")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: 60_000_000),
            toolCallId: "call-xyz"
        )
        let recorded = await store.recordedToolCallId(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding
        )
        #expect(recorded == "call-xyz")
    }

    @Test("waitForResolution resumes when approval is granted")
    func waitForResolutionResumesOnApprove() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let callBinding = binding("test_tool")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
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
        let callBinding = binding("cancel_tool")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waitTask.cancel()
        for _ in 0..<20 {
            if let resolved = await store.resolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
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
        let callBinding = binding("no_timeout_tool")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: nil)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = await store.resolution(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding
        )
        #expect(pending?.status == .pending)
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
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
        let callBinding = binding("no_timeout_cancel_tool")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: nil)
        )
        let waitTask = Task {
            try await store.waitForResolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waitTask.cancel()
        for _ in 0..<20 {
            if let resolved = await store.resolution(
                conversationID: conversationID,
                runID: runID,
                binding: callBinding
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
        let bindingA = binding("tool_a")
        let bindingB = binding("tool_b")
        _ = await store.registerPendingApproval(
            conversationID: conversationA,
            runID: runA,
            binding: bindingA,
            requestedAt: past,
            spec: makeSpec(timeoutMs: 1000)
        )
        _ = await store.registerPendingApproval(
            conversationID: conversationB,
            runID: runB,
            binding: bindingB,
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
            binding: bindingA
        )
        #expect(resolutionA?.status == .denied)
        #expect(resolutionA?.kind == .timeoutDefault)

        let resolutionB = await store.resolution(
            conversationID: conversationB,
            runID: runB,
            binding: bindingB
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
            binding: bindingB
        )
        #expect(resolvedB?.status == .denied)
        #expect(resolvedB?.kind == .timeoutDefault)
    }

    @Test("finite timeout still auto-denies after the configured window")
    func finiteTimeoutAutoDenies() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let callBinding = binding("finite_timeout_tool")
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding,
            spec: makeSpec(timeoutMs: 20)
        )
        let resolution = try await store.waitForResolution(
            conversationID: conversationID,
            runID: runID,
            binding: callBinding
        )
        #expect(resolution.status == .denied)
        #expect(resolution.kind == .timeoutDefault)
    }

    @Test("two concurrent pendings for same tool with different args resolve independently")
    func concurrentPendingsDifferentArgs() async throws {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let bindingA = binding("write_file", args: .object(["path": .string("/a")]))
        let bindingB = binding("write_file", args: .object(["path": .string("/b")]))
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: bindingA,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        _ = await store.registerPendingApproval(
            conversationID: conversationID,
            runID: runID,
            binding: bindingB,
            spec: makeSpec(timeoutMs: 60_000_000)
        )
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            binding: bindingA,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual
        )
        let resolvedA = await store.resolution(
            conversationID: conversationID,
            runID: runID,
            binding: bindingA
        )
        let pendingB = await store.resolution(
            conversationID: conversationID,
            runID: runID,
            binding: bindingB
        )
        #expect(resolvedA?.status == .approved)
        #expect(pendingB?.status == .pending)
    }

    @Test("approvedCallBindings exports allow-once only; approvedToolNames exports allow-always only")
    func approvedExportsSplitByDecision() async {
        let store = ToolApprovalStateStore()
        let conversationID = UUID()
        let runID = UUID()
        let onceBinding = binding("write_file", args: .object(["path": .string("/a")]))
        let alwaysBinding = binding("delete_file", args: .object(["path": .string("/x")]))
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            binding: onceBinding,
            status: .approved,
            source: "test",
            kind: .manual,
            decision: .allowOnce
        )
        await store.setResolution(
            conversationID: conversationID,
            runID: runID,
            binding: alwaysBinding,
            status: .approved,
            source: "test",
            kind: .manual,
            decision: .allowAlways
        )
        let bindings = await store.approvedCallBindings(
            conversationID: conversationID,
            runID: runID
        )
        let names = await store.approvedToolNames(
            conversationID: conversationID,
            runID: runID
        )
        #expect(bindings.contains(onceBinding))
        #expect(bindings.contains(alwaysBinding) == false)
        #expect(names.contains("delete_file"))
        #expect(names.contains("write_file") == false)
    }
}
