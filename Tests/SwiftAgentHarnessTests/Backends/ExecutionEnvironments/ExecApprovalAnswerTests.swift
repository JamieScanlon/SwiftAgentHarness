import Foundation
import Testing
@testable import SwiftAgentHarness

/// Waits until a delivery has registered `id`, so a resolve can't race ahead of it.
func awaitPendingApproval(_ id: String, in store: ExecApprovalStore) async throws {
    for _ in 0..<2_000 {
        if await store.pendingScope(id: id) != nil { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("approval \(id) never became pending")
}

private struct ApprovingDelivery: ExecApprovalDelivering {
    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult { .approved }
    func sendFollowup(approvalID: String, approved: Bool) async {}
}

@Suite("Exec approvals: where an approval was answered")
struct ExecApprovalAnswerTests {
    private let scope = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)

    private func request(_ id: String) -> ExecApprovalRequest {
        ExecApprovalRequest(id: id, command: "computer-use grant", title: "Allow computer use", description: "TextEdit", allowsDurableBypass: false)
    }

    @Test("An answer from a client away from the target comes back with the approval")
    func offTarget() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        async let answer = delivery.requestAnswer(request("grant-1"), headless: false)
        try await awaitPendingApproval("grant-1", in: store)
        let resolution = await store.resolve(
            id: "grant-1", scope: scope, strictTenancy: false, ownerScope: nil, approved: true, answeredOffTarget: true
        )
        #expect(resolution == .approved(durable: false))
        #expect(await answer == ExecApprovalAnswer(result: .approved, answeredOffTarget: true))
    }

    @Test("A client that doesn't say where it is counts as on the target, and requestApproval is unchanged")
    func undeclared() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        async let answer = delivery.requestAnswer(request("grant-2"), headless: false)
        try await awaitPendingApproval("grant-2", in: store)
        await store.resolve(id: "grant-2", scope: scope, strictTenancy: false, ownerScope: nil, approved: true)
        #expect(await answer == ExecApprovalAnswer(result: .approved, answeredOffTarget: false))

        async let approval = delivery.requestApproval(request("grant-3"), headless: false)
        try await awaitPendingApproval("grant-3", in: store)
        await store.resolve(id: "grant-3", scope: scope, strictTenancy: false, ownerScope: nil, approved: true, answeredOffTarget: true)
        #expect(await approval == .approved)
    }

    @Test("A denial keeps its reason whatever the client says about where it is")
    func denied() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        async let answer = delivery.requestAnswer(request("grant-4"), headless: false)
        try await awaitPendingApproval("grant-4", in: store)
        await store.resolve(
            id: "grant-4", scope: scope, strictTenancy: false, ownerScope: nil, approved: false, reason: "not now", answeredOffTarget: true
        )
        #expect(await answer.result == .denied("not now"))
    }

    @Test("An answer nobody gave, such as a headless refusal, isn't off the target")
    func headless() async {
        let delivery = DefaultExecApprovalDelivery(store: ExecApprovalStore(), approvalScope: scope, waitTimeoutSeconds: 5)
        let answer = await delivery.requestAnswer(request("grant-5"), headless: true)
        #expect(answer.answeredOffTarget == false)
        guard case .headlessDenied = answer.result else {
            Issue.record("expected a headless denial, got \(answer.result)")
            return
        }
    }

    @Test("A delivery that only implements requestApproval answers as on the target")
    func defaultAnswer() async {
        #expect(await ApprovingDelivery().requestAnswer(request("grant-6"), headless: false)
            == ExecApprovalAnswer(result: .approved, answeredOffTarget: false))
    }

    @Test("A computer-use confirmation keeps where it was answered while pausing the idle clock")
    func livenessWrapper() async throws {
        let store = ExecApprovalStore()
        let delivery = ComputerUseLivenessApprovals(
            base: DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5),
            liveness: DelegateLiveness()
        )
        async let answer = delivery.requestAnswer(request("grant-8"), headless: false)
        try await awaitPendingApproval("grant-8", in: store)
        await store.resolve(id: "grant-8", scope: scope, strictTenancy: false, ownerScope: nil, approved: true, answeredOffTarget: true)
        #expect(await answer == ExecApprovalAnswer(result: .approved, answeredOffTarget: true))
    }

    @Test("A card button or channel reply passes where it was answered through")
    func inbound() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        async let answer = delivery.requestAnswer(request("grant-7"), headless: false)
        try await awaitPendingApproval("grant-7", in: store)
        await ExecApprovalInbound.resolve(
            approvalID: "grant-7", actionID: "allow-once", scope: scope, strictTenancy: false, ownerScope: nil,
            store: store, answeredOffTarget: true
        )
        #expect(await answer == ExecApprovalAnswer(result: .approved, answeredOffTarget: true))
    }
}
