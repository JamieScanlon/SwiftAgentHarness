import Foundation
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private struct UnifiedBody: Content {
    var decision: String
    var answeredOffTarget: Bool?
}

private struct LegacyBody: Content {
    var approved: Bool
    var answeredOffTarget: Bool?
}

@Suite("APILayer approval routes: where an approval was answered")
struct APILayerApprovalAnswerRouteTests {
    private func resolve<Body: Content>(_ path: String, _ body: Body) async throws -> ExecApprovalAnswer {
        try await ExecApprovalStoreTestSupport.isolated {
            let id = "grant-\(UUID().uuidString)"
            let scope = ExecApprovalScope(conversationID: UUID(), ownerAccountID: nil)
            let delivery = DefaultExecApprovalDelivery(store: .shared, approvalScope: scope, waitTimeoutSeconds: 5)
            let request = ExecApprovalRequest(
                id: id, command: "computer-use grant", title: "Allow computer use", description: "TextEdit", allowsDurableBypass: false
            )
            async let answer = delivery.requestAnswer(request, headless: false)
            try await awaitPendingApproval(id, in: .shared)
            let api = APILayer(port: 0)
            try await withApp { app in
                await api.configureRoutesForTesting(
                    app: app,
                    conversation: ProtocolOnlyConversationGatewayStub(),
                    runtime: ProtocolOnlyRuntimeGatewayStub(),
                    modelProvider: APILayerRESTStubModelProvider(models: [])
                )
                try await app.testing().test(.POST, "/api/\(path)/\(id)", beforeRequest: { req in
                    try req.content.encode(body)
                }) { res async throws in
                    #expect(res.status == .ok)
                }
            }
            return await answer
        }
    }

    @Test("POST /api/approvals/:id carries a client's answeredOffTarget to the waiting delivery")
    func unified() async throws {
        #expect(try await resolve("approvals", UnifiedBody(decision: "allowOnce", answeredOffTarget: true))
            == ExecApprovalAnswer(result: .approved, answeredOffTarget: true))
        #expect(try await resolve("approvals", UnifiedBody(decision: "allowOnce"))
            == ExecApprovalAnswer(result: .approved, answeredOffTarget: false))
    }

    @Test("POST /api/exec-approvals/:id carries a client's answeredOffTarget to the waiting delivery")
    func legacy() async throws {
        #expect(try await resolve("exec-approvals", LegacyBody(approved: true, answeredOffTarget: true))
            == ExecApprovalAnswer(result: .approved, answeredOffTarget: true))
        #expect(try await resolve("exec-approvals", LegacyBody(approved: true))
            == ExecApprovalAnswer(result: .approved, answeredOffTarget: false))
    }
}
