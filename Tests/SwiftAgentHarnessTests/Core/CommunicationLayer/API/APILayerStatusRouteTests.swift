import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer status routes")
struct APILayerStatusRouteTests {
    @Test("GET /api/status returns running state")
    func statusEndpoint() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/status") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["status"] as? String == "running")
                #expect(json?["sessions"] is Int)
                #expect(json.map { Set($0.keys) } == Set(["status", "sessions"]))
            }
        }
    }

    @Test("GET /api/system_prompt/full returns prompt payload")
    func fullSystemPromptEndpoint() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub(defaultSystemPrompt: "stubbed-full-prompt")
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/system_prompt/full") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect((json?["fullSystemPrompt"] as? String)?.isEmpty == false)
                #expect(json.map { Set($0.keys) } == Set(["fullSystemPrompt"]))
            }
        }
    }

}
