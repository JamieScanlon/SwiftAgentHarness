import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Collects the state envelopes a connection receives.
private actor StateLines {
    private var payloads: [CommResourceTopicMessage<ConversationStatePayload>] = []

    func append(_ json: String) {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder.iso8601.decode(CommResourceTopicMessage<ConversationStatePayload>.self, from: data)
        else { return }
        payloads.append(envelope)
    }

    func all() -> [CommResourceTopicMessage<ConversationStatePayload>] { payloads }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite("Conversation state: pending approvals")
struct APILayerPendingApprovalsStateTests {
    private static func conversation() -> ModelConversation {
        ModelConversation(model: Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "pending-approvals",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        ))
    }

    @Test("The snapshot lists the conversation's pending approvals, and omits the field when there are none")
    func snapshot() async {
        let row = Self.conversation()
        let stub = SnapshotConversationStub(conversation: row)
        let summary = PendingApprovalSummary(
            approvalID: "grant-1", kind: PendingApprovalSummary.execKind, title: "Allow computer use",
            command: "computer-use grant", presentation: nil, requestedAt: Date(timeIntervalSince1970: 5)
        )
        let listed = await ConversationStateSnapshotBuilder.build(
            conversationID: row.id, conversation: stub, runtime: nil,
            pendingApprovalsProvider: { $0 == row.id ? [summary] : [] }
        )
        #expect(listed.pendingApprovals == [summary])

        let none = await ConversationStateSnapshotBuilder.build(
            conversationID: row.id, conversation: stub, runtime: nil,
            pendingApprovalsProvider: { _ in [] }
        )
        #expect(none.pendingApprovals == nil)
    }

    @Test("Raising and resolving an approval rebroadcasts the conversation's state")
    func rebroadcasts() async throws {
        let row = Self.conversation()
        let store = ExecApprovalStore()
        let hub = ConversationStateTopicHub()
        let api = APILayer(port: 0)
        await api.setChatGatewayServices(APILayerChatGatewayServices(
            conversation: SnapshotConversationStub(conversation: row),
            runtime: ProtocolOnlyRuntimeGatewayStub()
        ))
        await api.setConversationStateWireResources(hub: hub)
        await api.setExecApprovalStore(store)
        await api.startWatchingPendingApprovals()
        defer { Task { await api.stop() } }

        let lines = StateLines()
        let token = await hub.registerConnection { line in Task { await lines.append(line.json) } }
        try await hub.subscribe(token: token, conversationID: row.id, since: nil) { cid in
            ConversationStatePayload(conversationID: cid, exists: true, sessionSelected: false)
        }

        let scope = ExecApprovalScope(conversationID: row.id, ownerAccountID: nil)
        await store.registerPending(id: "grant-2", command: "computer-use grant", scope: scope, title: "Allow computer use")
        try await waitUntil { await lines.all().contains { $0.value?.pendingApprovals?.map(\.approvalID) == ["grant-2"] } }

        await store.resolve(id: "grant-2", scope: scope, strictTenancy: false, ownerScope: nil, approved: true)
        try await waitUntil {
            guard let last = await lines.all().last else { return false }
            return last.kind == .event && last.value?.exists == true && last.value?.pendingApprovals == nil
        }
        await hub.unregisterConnection(token)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("condition never held")
    }
}
