import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Exec approvals: listing what is still waiting")
struct ExecApprovalPendingListTests {
    private let conversationID = UUID()
    private var scope: ExecApprovalScope { ExecApprovalScope(conversationID: conversationID, ownerAccountID: nil) }

    private func request(_ id: String) -> ExecApprovalRequest {
        ExecApprovalRequest(id: id, command: "computer-use grant", title: "Allow computer use", description: "TextEdit", allowsDurableBypass: false)
    }

    @Test("A raised approval is listed for its conversation with what a client needs to show it")
    func listsRaised() async {
        let store = ExecApprovalStore()
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let presentation = ApprovalPresentation.standard(title: "Allow computer use", context: ["TextEdit"])
        await store.registerPending(
            id: "grant-1", command: "computer-use grant", scope: scope, allowsDurableBypass: false,
            presentation: presentation, title: "Allow computer use", requestedAt: requestedAt
        )
        await store.registerPending(
            id: "other", command: "ls", scope: ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
        )

        #expect(await store.pendingApprovals(conversationID: conversationID) == [
            PendingApprovalSummary(
                approvalID: "grant-1", kind: PendingApprovalSummary.execKind, title: "Allow computer use",
                command: "computer-use grant", presentation: presentation, requestedAt: requestedAt
            ),
        ])
    }

    @Test("Approvals are listed oldest first, and one without a title shows its command")
    func ordering() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "b", command: "rm -rf build", scope: scope, requestedAt: Date(timeIntervalSince1970: 2))
        await store.registerPending(id: "a", command: "make", scope: scope, title: "Run make", requestedAt: Date(timeIntervalSince1970: 1))

        let listed = await store.pendingApprovals(conversationID: conversationID)
        #expect(listed.map(\.approvalID) == ["a", "b"])
        #expect(listed.map(\.title) == ["Run make", "rm -rf build"])
    }

    @Test("A resolved approval is no longer listed")
    func resolvedLeaves() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "grant-2", command: "computer-use grant", scope: scope)
        await store.resolve(id: "grant-2", scope: scope, strictTenancy: false, ownerScope: nil, approved: true)
        #expect(await store.pendingApprovals(conversationID: conversationID).isEmpty)
    }

    @Test("A withdrawn approval is no longer listed and can't be answered")
    func withdrawnLeaves() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "grant-3", command: "computer-use grant", scope: scope)
        await store.withdraw(id: "grant-3")
        #expect(await store.pendingApprovals(conversationID: conversationID).isEmpty)
        #expect(await store.pendingScope(id: "grant-3") == nil)
        #expect(await store.resolve(id: "grant-3", scope: scope, strictTenancy: false, ownerScope: nil, approved: true) == nil)
    }

    @Test("Raising, resolving and withdrawing each announce the conversation whose approvals changed")
    func announcesChanges() async {
        let store = ExecApprovalStore()
        let changes = await store.pendingApprovalChanges()
        var iterator = changes.makeAsyncIterator()

        await store.registerPending(id: "grant-4", command: "computer-use grant", scope: scope)
        #expect(await iterator.next() == conversationID)
        await store.resolve(id: "grant-4", scope: scope, strictTenancy: false, ownerScope: nil, approved: false)
        #expect(await iterator.next() == conversationID)
        await store.registerPending(id: "grant-5", command: "computer-use grant", scope: scope)
        #expect(await iterator.next() == conversationID)
        await store.withdraw(id: "grant-5")
        #expect(await iterator.next() == conversationID)
    }

    @Test("A rejected resolve or withdrawing an unknown approval announces nothing")
    func quietWhenNothingChanged() async {
        let store = ExecApprovalStore()
        let changes = await store.pendingApprovalChanges()
        var iterator = changes.makeAsyncIterator()

        await store.registerPending(id: "grant-6", command: "computer-use grant", scope: scope)
        #expect(await iterator.next() == conversationID)
        let stranger = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
        #expect(await store.resolve(id: "grant-6", scope: stranger, strictTenancy: false, ownerScope: nil, approved: true) == nil)
        await store.withdraw(id: "never-raised")
        let marker = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
        await store.registerPending(id: "marker", command: "ls", scope: marker)
        #expect(await iterator.next() == marker.conversationID)
    }

    @Test("A delivery whose wait ends unanswered withdraws its approval")
    func deliveryWithdrawsOnTimeout() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 0.05)
        let answer = await delivery.requestAnswer(request("grant-7"), headless: false)
        #expect(answer.result == .denied("exec approval cancelled"))
        #expect(await store.pendingApprovals(conversationID: conversationID).isEmpty)
    }

    @Test("A delivery lists its approval under the request's title while it waits")
    func deliveryListsTitle() async throws {
        let store = ExecApprovalStore()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        async let answer = delivery.requestAnswer(request("grant-8"), headless: false)
        try await awaitPendingApproval("grant-8", in: store)
        let listed = await store.pendingApprovals(conversationID: conversationID)
        #expect(listed.map(\.title) == ["Allow computer use"])
        #expect(listed.first?.presentation == request("grant-8").presentation)
        await store.resolve(id: "grant-8", scope: scope, strictTenancy: false, ownerScope: nil, approved: true)
        #expect(await answer.result == .approved)
    }

    @Test("The summary round-trips through JSON")
    func codable() throws {
        let summary = PendingApprovalSummary(
            approvalID: "grant-9", kind: PendingApprovalSummary.execKind, title: "Allow computer use",
            command: "computer-use grant", presentation: .standard(title: "Allow computer use"),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PendingApprovalSummary.self, from: encoder.encode(summary)) == summary)
    }
}
