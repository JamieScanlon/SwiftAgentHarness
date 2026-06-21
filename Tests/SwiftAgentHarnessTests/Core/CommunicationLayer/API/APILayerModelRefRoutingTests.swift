import Foundation
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private final class ModelRefStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    init(models: [Model]) { self.models = models }
    func getAvailableModels() async -> [Model] { models }
}

private enum ModelRefRoutingTestSupport {
    static func makeTestModel(id: UUID = UUID(), slug: String = "test-model") -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: slug,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

@Suite("APILayer modelRef routing", .serialized)
struct APILayerModelRefRoutingTests {

    @Test("POST /api/conversations accepts modelRef as UUID")
    func createConversationAcceptsModelRefUUID() async throws {
        let model = ModelRefRoutingTestSupport.makeTestModel(slug: "llama3.3:latest")
        let modelProvider = ModelRefStubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let json = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "create")
            })
        }
    }

    @Test("POST /api/conversations accepts modelRef as slug")
    func createConversationAcceptsModelRefSlug() async throws {
        let model = ModelRefRoutingTestSupport.makeTestModel(slug: "llama3.3:latest")
        let modelProvider = ModelRefStubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let json = #"{"modelRef":"llama3.3:latest","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "create")
            })
        }
    }

    @Test("POST /api/conversations requires modelRef")
    func createConversationRejectsMissingModelRef() async throws {
        let modelProvider = ModelRefStubModelProvider(models: [])
        let api = APILayer(port: 0)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let json = #"{"userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "error")
                #expect((body?["message"] as? String)?.contains("modelRef") == true)
            })
        }
    }

    @Test("POST /api/conversations rejects unknown modelRef with badRequest error")
    func createConversationRejectsUnknownModelRef() async throws {
        let model = ModelRefRoutingTestSupport.makeTestModel(slug: "llama3.3:latest")
        let modelProvider = ModelRefStubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let json = #"{"modelRef":"not-a-real-slug","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "error")
                #expect((body?["message"] as? String)?.contains("Model not found") == true)
            })
        }
    }

    @Test("POST /api/conversations keeps unknown modelRef loud-fail even with modeProfileID")
    func createConversationRejectsUnknownModelRefWithModeProfile() async throws {
        let model = ModelRefRoutingTestSupport.makeTestModel(slug: "llama3.3:latest")
        let modelProvider = ModelRefStubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, conversation: conversation, runtime: runtime, modelProvider: modelProvider)
            let json = #"{"modelRef":"not-a-real-slug","modeProfileID":"agent","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "error")
                #expect((body?["message"] as? String)?.contains("Model not found") == true)
            })
        }
    }
}
