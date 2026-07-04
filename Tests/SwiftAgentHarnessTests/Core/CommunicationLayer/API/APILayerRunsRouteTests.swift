import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer runs routes")
struct APILayerRunsRouteTests {
    @Test("POST /api/conversations/:id/cancel returns 409 run_not_in_flight without active run")
    func conversationCancelWithoutActiveRunReturnsConflict() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"cancel-idempotent"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let requestedRunID = UUID()
            let body = #"{"runId":"\#(requestedRunID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/cancel", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["code"] as? String == "run_not_in_flight")
            })
        }
    }

}
