import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

private final class StubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    let error: Error?

    init(models: [Model] = [], error: Error? = nil) {
        self.models = models
        self.error = error
    }

    func getAvailableModels() async -> [Model] {
        if error != nil {
            return []
        }
        return models
    }
}

private enum APILayerRESTTestSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeTestModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeChatManager(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    static let strictTenancyAuthSettings = APIAccessTokenAuthenticationSettings(hs256Secret: "rest-coverage-test-secret")

    static func configureStrictTenancyAuth(on api: APILayer) async {
        await api.setTenancyPolicySettings(TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true))
        await api.setAPIAccessTokenAuthenticationSettings(strictTenancyAuthSettings)
    }

    static func bearerAuthorization(ownerAccountID: UUID) async throws -> String {
        try await HarnessAPIAccessTokenFactory.authorizationHeaderValue(
            ownerAccountID: ownerAccountID,
            settings: strictTenancyAuthSettings
        )
    }
}

@Suite("APILayer REST routes", .serialized)
struct APILayerRESTCoverageTests {

    @Test("GET /api/status returns running state")
    func statusEndpoint() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
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
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
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

    @Test("GET /api/models returns empty models on provider error")
    func listModelsFallbackOnError() async throws {
        enum TestError: Error { case boom }
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [], error: TestError.boom)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/models") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let models = json?["models"] as? [Any]
                #expect(models?.isEmpty == true)
            }
        }
    }

    @Test("GET /api/models returns configured models")
    func listModelsSuccess() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/models") { res async throws in
                #expect(res.status == .ok)
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let models = json?["models"] as? [[String: Any]]
                #expect(models?.count == 1)
                #expect(models?.first?["id"] as? String == model.id.uuidString)
                #expect(models?.first?["modelName"] as? String == model.modelName)
            }
        }
    }

    @Test("GET /api/models returns 304 when If-None-Match matches ETag")
    func modelsListIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var etag = ""
            try await app.testing().test(.GET, "/api/models") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/models", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/models returns 304 when If-None-Match is wildcard")
    func modelsListIfNoneMatchWildcardReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/models", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: "*")
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/models/:id/state returns model state snapshot")
    func modelStateSnapshotRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let hub = ModelStateTopicHub()
        let coordinator = ModelInvocationCoordinator()
        await api.setModelStateWireResources(hub: hub, coordinator: coordinator)
        let callID = await coordinator.beginCall(modelID: model.id, conversationID: UUID())
        await coordinator.recordTransition(modelID: model.id, phase: .streaming, callID: callID)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/models/\(model.id.uuidString)/state") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let modelIDRaw = body?["modelID"] as? String
                #expect(UUID(uuidString: modelIDRaw ?? "") == model.id)
                let state = body?["state"] as? [String: Any]
                #expect(state?["phase"] as? String == "streaming")
            }
        }
    }

    @Test("GET /api/models/:id/calls returns active call ledger")
    func modelCallsSnapshotRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)
        let hub = ModelStateTopicHub()
        let coordinator = ModelInvocationCoordinator()
        await api.setModelStateWireResources(hub: hub, coordinator: coordinator)
        let callID = await coordinator.beginCall(modelID: model.id, conversationID: UUID())
        await coordinator.recordTransition(modelID: model.id, phase: .connecting, callID: callID)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/models/\(model.id.uuidString)/calls") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let calls = body?["calls"] as? [String: Any]
                let active = calls?["active"] as? [[String: Any]]
                #expect(active?.contains(where: { ($0["callID"] as? String)?.lowercased() == callID.uuidString.lowercased() }) == true)
            }
        }
    }

    @Test("Conversation create/read/delete routes complete with valid IDs")
    func conversationLifecycleRoutes() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "create")
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(createdConversationID)") { res async throws in
                #expect(res.status == .ok)
                let row = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(row?["id"] as? String == createdConversationID)
            }

            try await app.testing().test(.DELETE, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("POST /api/conversations accepts topic, description, and metadata")
    func conversationCreateWithTopicAndDescription() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys","topic":"REST Topic","description":"REST Description","metadata":{"source":"rest-create"},"modeProfileID":"custom.profile.alpha"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "create")
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let items = payload?["items"] as? [[String: Any]]
                let conversation = try #require(items?.first)
                #expect(conversation["topic"] as? String == "REST Topic")
                #expect(conversation["description"] as? String == "REST Description")
                #expect(payload?["totalCount"] as? Int == 1)
                #expect(payload?["conversations"] == nil)
            }

            try await app.testing().test(.GET, "/api/conversations/\(createdConversationID)") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(payload?["modeProfileID"] as? String == "custom.profile.alpha")
                let metadata = payload?["metadata"] as? [String: Any]
                #expect(metadata?["source"] as? String == "rest-create")
            }
        }
    }

    @Test("POST /api/conversations persists an explicit cwd")
    func conversationCreatePersistsCwd() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys","cwd":"/trusted/rest/root"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "create")
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let createdID = try #require(UUID(uuidString: createdConversationID))
            let conversation = try #require(await runtimeSession.modelConversation(id: createdID))
            #expect(conversation.harnessPersistenceCwd == "/trusted/rest/root")
        }
    }

    @Test("POST /api/conversations without cwd still succeeds and uses the default")
    func conversationCreateWithoutCwdSucceeds() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let createdID = try #require(UUID(uuidString: createdConversationID))
            let conversation = try #require(await runtimeSession.modelConversation(id: createdID))
            #expect(conversation.harnessPersistenceCwd != "/trusted/rest/root")
        }
    }

    @Test("PATCH /api/conversations/:id updates topic and description")
    func conversationUpdateMetadataRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let updateJSON = #"{"expectedRevision":1,"topic":"Updated via REST","description":"Updated description via REST","metadata":{"source":"rest-update"},"modeProfileID":"custom.profile.beta"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "update")
                #expect((body?["controlPlaneRevision"] as? NSNumber)?.uint64Value != nil)
            })

            try await app.testing().test(.GET, "/api/conversations") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let items = payload?["items"] as? [[String: Any]]
                let conversation = try #require(items?.first)
                #expect(conversation["topic"] as? String == "Updated via REST")
                #expect(conversation["description"] as? String == "Updated description via REST")
            }

            try await app.testing().test(.GET, "/api/conversations/\(createdConversationID)") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let metadata = payload?["metadata"] as? [String: Any]
                #expect(metadata?["source"] as? String == "rest-update")
                #expect(payload?["modeProfileID"] as? String == "custom.profile.beta")
            }
        }
    }

    @Test("PATCH /api/conversations/:id updates thinkingEnabled")
    func conversationUpdateThinkingPreferenceRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let updateJSON = #"{"expectedRevision":1,"routingModelOptions":{"thinkingConfig":"disabled"}}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "update")
                #expect((body?["controlPlaneRevision"] as? NSNumber)?.uint64Value != nil)
            })

            try await app.testing().test(.GET, "/api/conversations/\(createdConversationID)") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let routing = json?["routingPrefs"] as? [String: Any]
                let modelOptions = routing?["modelOptions"] as? [String: Any]
                #expect(modelOptions?["thinkingConfig"] as? String == "disabled")
            }
        }
    }

    @Test("PATCH /api/conversations/:id updates reasoningEffort")
    func conversationUpdateReasoningEffortRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let updateJSON = #"{"expectedRevision":1,"routingModelOptions":{"thinkingConfig":{"level":"low"}}}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "update")
                #expect((body?["controlPlaneRevision"] as? NSNumber)?.uint64Value != nil)
            })

            try await app.testing().test(.GET, "/api/conversations/\(createdConversationID)") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let routing = json?["routingPrefs"] as? [String: Any]
                let modelOptions = routing?["modelOptions"] as? [String: Any]
                let thinkingConfig = modelOptions?["thinkingConfig"] as? [String: Any]
                #expect(thinkingConfig?["level"] as? String == "low")
            }
        }
    }

    @Test("PATCH /api/conversations/:id returns 409 when expectedRevision is stale")
    func conversationPatchRevisionMismatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID: String = ""

            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let bumpJSON = #"{"expectedRevision":1,"topic":"first writer"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: bumpJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let staleJSON = #"{"topic":"second writer","expectedRevision":0}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: staleJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["code"] as? String == ConversationRevisionConflictBody.errorCode)
                #expect((body?["currentRevision"] as? NSNumber)?.uint64Value ?? 0 >= 1)
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns 400 when expectedRevision is missing")
    func conversationPatchRequiresExpectedRevision() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var createdConversationID = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                createdConversationID = (body?["conversationID"] as? String) ?? ""
                #expect(createdConversationID.isEmpty == false)
            })

            let updateJSON = #"{"topic":"missing revision"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(createdConversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns 412 for stale If-Match")
    func conversationPatchIfMatchPreconditionFailed() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var conversationID = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            let updateJSON = #"{"topic":"should fail by precondition"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(conversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v999\"")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionFailed)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_failed")
                #expect((json?["currentVersion"] as? String)?.hasPrefix("conv-v") == true)
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns 428 without If-Match when strict mode enabled")
    func conversationPatchStrictModeRequiresIfMatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var conversationID = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            let updateJSON = #"{"topic":"strict mode update"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(conversationID)", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns structured error for invalid ID")
    func conversationPatchInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.PATCH, "/api/conversations/not-a-uuid", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"topic":"bad"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns structured error for missing conversation")
    func conversationPatchMissingConversationReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.PATCH, "/api/conversations/\(UUID())", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"topic":"bad"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Conversation not found") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/revert returns structured error for invalid ID")
    func conversationRevertInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/not-a-uuid/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/revert returns structured error for missing body fields")
    func conversationRevertMissingBodyFieldsReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"includeTools":true}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Expected JSON body with userMessageID") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/revert returns structured error for missing conversation")
    func conversationRevertMissingConversationReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub(revertRouteError: .conversationNotFound)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/\(UUID())/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Conversation not found") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/revert returns structured error for invalid anchor")
    func conversationRevertInvalidAnchorReturnsStructuredError() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            let revertJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/revert", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: revertJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid revert anchor") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns structured error for invalid ID")
    func conversationBranchInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/not-a-uuid/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns structured error for missing body fields")
    func conversationBranchMissingBodyFieldsReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"topic":"wrong-shape"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Expected JSON body with userMessageID") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns structured error for missing conversation")
    func conversationBranchMissingConversationReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub(branchRouteError: .conversationNotFound)
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/\(UUID())/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Conversation not found") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns structured error for invalid anchor")
    func conversationBranchInvalidAnchorReturnsStructuredError() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            let branchJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid branch anchor") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns 428 without If-Match when strict preconditions enabled")
    func conversationBranchStrictModeRequiresIfMatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let branchJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("POST /api/conversations/:id/branch returns 412 for stale If-Match when strict preconditions enabled")
    func conversationBranchStrictModePreconditionFailed() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
            })

            let branchJSON = #"{"userMessageID":"00000000-0000-0000-0000-000000000001"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"msg-00000000-0000-0000-0000-000000000099\"")
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .preconditionFailed)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_failed")
            })
        }
    }

    @Test("POST /api/conversations/:id/branch succeeds with matching transcript-tail If-Match when strict preconditions enabled")
    func conversationBranchStrictModeSucceedsWithTailETag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-rest-branch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try APILayerRESTTestSupport.makeContainer()
        let harness = try LocalHarnessSessionPersistence(root: root)
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: harness
        )
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
            })

            let convUUID = try #require(UUID(uuidString: cid))
            let conversation = try #require(await runtimeSession.testing_modelConversation(conversationID: convUUID))
            await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
            await runtimeSession.testing_setActiveStreamingRun(conversationID: convUUID, runID: UUID())
            let userMsgID = UUID()
            await runtimeSession.testing_applyOrchestratorMessages([
                Message(id: userMsgID, role: .user, content: "branch-anchor", timestamp: Date(), toolCalls: []),
            ])

            let tailTag = "\"msg-\(userMsgID.uuidString.lowercased())\""
            let branchJSON = #"{"userMessageID":"\#(userMsgID.uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(cid)/branch", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: tailTag)
                req.body = .init(string: branchJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("GET /api/conversations paged list auto-scopes to bearer owner under strict tenancy")
    func strictTenancyPagedListAutoScopesToBearerOwner() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let ownerA = UUID()
        let ownerB = UUID()
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)
        let authA = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: ownerA)
        let authB = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: ownerB)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cidA = ""
            var cidB = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authA)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cidA = (body?["conversationID"] as? String) ?? ""
            })
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authB)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cidB = (body?["conversationID"] as? String) ?? ""
            })

            try await app.testing().test(
                .GET,
                "/api/conversations?summary=true&limit=50",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    let items = json?["items"] as? [[String: Any]]
                    let ids = items?.compactMap { $0["id"] as? String } ?? []
                    #expect(ids.contains(cidA))
                    #expect(ids.contains(cidB) == false)
                }
            )

            try await app.testing().test(
                .GET,
                "/api/conversations?summary=true&limit=50&owner=\(ownerA.uuidString)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    let items = json?["items"] as? [[String: Any]]
                    let ids = items?.compactMap { $0["id"] as? String } ?? []
                    #expect(ids.contains(cidA))
                    #expect(ids.contains(cidB) == false)
                }
            )

            try await app.testing().test(
                .GET,
                "/api/conversations?summary=true&limit=50&owner=\(ownerB.uuidString)",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authA)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .forbidden)
                }
            )

            try await app.testing().test(
                .GET,
                "/api/conversations?summary=true&limit=50",
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    @Test("GET /api/conversations/:id returns 304 when If-None-Match matches ETag")
    func conversationGetIfNoneMatchReturnsNotModified() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))

            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var conversationID = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
            })

            var etag = ""
            try await app.testing().test(.GET, "/api/conversations/\(conversationID)") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/conversations/\(conversationID)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/conversations/select/:id returns notFound (route removed)")
    func conversationSelectRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/select/not-a-uuid") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations returns paged summary shape")
    func conversationListRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test")
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let items = json?["items"] as? [Any]
                #expect(items?.isEmpty == false)
                #expect(json?.keys.contains("items") == true)
                #expect(json?.keys.contains("totalCount") == true)
                #expect(json?.keys.contains("conversations") == false)
            }
        }
    }

    @Test("GET /api/conversations/:id returns conversation listed in catalog when registry was cleared")
    func conversationGetHydratesFromCatalogAfterRegistryCleared() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationID = try await runtimeSession.createConversation(with: model, userSystemPrompt: "catalog-get-hydrate")
        await runtimeSession.evictRegistryForTesting()
        #expect(await runtimeSession.listConversationInfo().isEmpty)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations?limit=200&offset=0") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let items = json?["items"] as? [[String: Any]] ?? []
                #expect(items.contains { ($0["id"] as? String) == conversationID.uuidString })
            }
            try await app.testing().test(.GET, "/api/conversations/\(conversationID)") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["id"] as? String == conversationID.uuidString)
            }
        }
    }

    @Test("GET /api/conversations with limit/offset query returns paged summary shape")
    func conversationListRouteWithQueryParameters() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test-query")
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations?limit=200&offset=0") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?.keys.contains("items") == true)
                #expect(json?.keys.contains("totalCount") == true)
                #expect(json?.keys.contains("conversations") == false)
            }
        }
    }

    @Test("GET /api/conversations/ (trailing slash) returns paged summary shape")
    func conversationListRouteTrailingSlash() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test-trailing-slash")
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/?limit=10&offset=0") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?.keys.contains("items") == true)
                #expect(json?.keys.contains("totalCount") == true)
            }
        }
    }

    @Test("GET /api/conversations excludes soft-deleted conversations by default")
    func conversationListRouteExcludesSoftDeleted() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationID = try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-soft-delete-test")
        try await runtimeSession.deleteConversation(conversationID: conversationID, hard: false)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations") { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = payload?["items"] as? [[String: Any]] ?? []
                let listedIDs = Set(rows.compactMap { $0["id"] as? String })
                #expect(listedIDs.contains(conversationID.uuidString) == false)
            }
        }
    }

    @Test("GET /api/conversations paged list returns 400 for malformed owner query")
    func conversationPagedListBadOwnerQuery() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations?limit=10&owner=not-a-uuid") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/search returns 400 for malformed owner query")
    func conversationSearchBadOwnerQuery() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/search?q=hello&owner=not-a-uuid") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/conversations/:id returns notFound for invalid UUID")
    func conversationGetInvalidUUID() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/not-a-uuid") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id returns notFound for non-existent conversation")
    func conversationGetNotFound() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        let missingID = UUID().uuidString

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(missingID)") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id returns full conversation with messages")
    func conversationGetSuccess() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "get-test", topic: "Test topic", description: "Test description")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["id"] as? String == convID.uuidString)
                let modelObj = json?["model"] as? [String: Any]
                #expect(modelObj?["modelName"] as? String == model.modelName)
                #expect(json?["topic"] as? String == "Test topic")
                #expect(json?["description"] as? String == "Test description")
                let messages = json?["messages"] as? [[String: Any]]
                #expect(messages?.isEmpty == false)
                #expect(messages?.contains { ($0["content"] as? String) == "get-test" } == true)
            }
        }
    }

    @Test("GET /api/conversations/:id/checkpoints/latest returns all checkpoint taxonomy kinds")
    func conversationLatestCheckpointTaxonomyKinds() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        var model = APILayerRESTTestSupport.makeTestModel()
        model.maxContextLength = 2_500
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-taxonomy")
        let convID = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.selectConversation(conversationID: convID)
        await runtimeSession.appendMessagesToConversation([
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a3", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u4", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "checkpoint-seed-a4", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "checkpoint-seed-u5", timestamp: Date(), toolCalls: []),
        ], conversationID: convID)
        let rawMessages = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiListMessagesThrowing(conversationID: convID)
        let compactionConfig = ConversationTransformConfiguration.default.contextCompaction
        let modelLimit = model.maxContextLength ?? compactionConfig.fallbackContextLimitTokens
        let rawMiddle = ContextCompactionCheckpointSupport.rawMiddle(
            from: rawMessages,
            config: compactionConfig,
            modelContextLimitTokens: modelLimit
        )
        let rawMiddleID = try #require(rawMiddle.first?.id)
        let rawAnyID = rawMiddleID
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        try derived.appendContextCompactionCheckpoint(
            conversationID: convID,
            rawMiddleMessageIDs: [rawMiddleID],
            compactedMiddleMessages: [Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])],
            coveredRawMiddle: rawMiddle,
            kind: .summarized,
            config: compactionConfig,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        try derived.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: convID,
            wire: MemoryInjectionSnapshotCheckpointWire(
                schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                injectionFingerprint: "mem-fp",
                snapshotJSON: "{\"a\":1}",
                scopeMessageIDs: [rawAnyID],
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )
        try derived.appendToolResultTrimCheckpoint(
            conversationID: convID,
            wire: ToolResultTrimCheckpointWire(
                schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                coveredMessageIDs: [rawAnyID],
                trimmedToolCallIds: ["tool-1"],
                configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )
        try derived.appendSystemPromptAssemblyCheckpoint(
            conversationID: convID,
            wire: SystemPromptAssemblyCheckpointWire(
                schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                assemblyFingerprint: "sys-fp",
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )

        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)

            let kinds = [
                HarnessCheckpointWireKind.contextCompaction.rawValue,
                HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue,
                HarnessCheckpointWireKind.toolResultTrim.rawValue,
                HarnessCheckpointWireKind.systemPromptAssembly.rawValue,
            ]
            for kind in kinds {
                try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=\(kind)") { res async throws in
                    #expect(res.status == .ok)
                    let body = Data(res.body.readableBytesView)
                    let payload = try JSONDecoder().decode(LatestCheckpointResponse.self, from: body)
                    #expect(payload.kind == kind)
                }
            }
        }
    }

    @Test("GET /api/conversations/:id/checkpoints/latest returns notFound for unknown kind")
    func conversationLatestCheckpointInvalidKind() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-invalid-kind")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=bad_kind") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/checkpoints/latest returns 304 when If-None-Match matches")
    func conversationLatestCheckpointIfNoneMatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "checkpoint-etag")
        let convID = try #require(await runtimeSession.currentConversationID)
        let derived = HarnessConversationTestFixtures.makeDerivedStore(container: container)
        try derived.appendSystemPromptAssemblyCheckpoint(
            conversationID: convID,
            wire: SystemPromptAssemblyCheckpointWire(
                schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                basedOnEventID: 0,
                assemblyFingerprint: "etag-fp",
                createdAt: Date()
            ),
            expectedDerivedSequence: nil
        )

        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            var etag = ""
            let url = "/api/conversations/\(convID.uuidString)/checkpoints/latest?kind=\(HarnessCheckpointWireKind.systemPromptAssembly.rawValue)"
            try await app.testing().test(.GET, url) { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }
            try await app.testing().test(.GET, url, beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/conversations/:id?includeDerived=true returns conversation plus raw/derived arrays")
    func conversationGetIncludeDerivedSuccess() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "include-derived-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)?includeDerived=true") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let conversation = json?["conversation"] as? [String: Any]
                #expect(conversation?["id"] as? String == convID.uuidString)
                #expect(json?["rawEvents"] is [[String: Any]])
                #expect(json?["derivedEvents"] is [[String: Any]])
            }
        }
    }

    @Test("POST /api/conversations/:id/projection returns projected messages and metadata")
    func conversationProjectionEndpointSuccess() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "projection-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.POST, "/api/conversations/\(convID.uuidString)/projection", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"config":{"options":{"debug":"rest"}}}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["projectedMessages"] is [[String: Any]])
                let metadata = json?["metadata"] as? [String: Any]
                #expect(metadata?["frontierEventID"] is NSNumber)
                #expect(metadata?["rawEventCount"] is NSNumber)
                #expect(metadata?["derivedEventCount"] is NSNumber)
            })
        }
    }

    @Test("GET /api/conversations/:id/server-metadata returns conversation server metadata (incl. context compaction gating)")
    func conversationGetServerMetadata() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "gating-test", topic: nil, description: nil)
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(
                .GET,
                "/api/conversations/\(convID.uuidString)/server-metadata"
            ) { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let m = try JSONDecoder().decode(ConversationServerMetadata.self, from: data)
                let g = m.contextCompactionGating
                #expect(g.charactersPerToken > 0)
                #expect(g.proactiveThresholdTokens > 0)
                #expect(g.modelContextLimitTokens > 0)
                #expect(g.contextCompactionConfigEnabled == true)
                #expect(g.enableContextTransform == true)
            }
        }
    }

    @Test("GET /api/conversations/:id/slash-commands returns JSON autocomplete rows")
    func conversationSlashCommandsList() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "slash-api-test")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.GET, "/api/conversations/\(convID.uuidString)/slash-commands") { res async throws in
                #expect(res.status == .ok)
                let rows = try JSONDecoder().decode([SlashCommandAutocompleteEntry].self, from: Data(res.body.readableBytesView))
                #expect(rows.contains { $0.name == "/compact" })
            }
        }
    }

    @Test("GET /api/conversations/:id/orchestration-state route is removed")
    func conversationOrchestrationStateRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/orchestration-state") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/turn-state route is removed")
    func conversationTurnStateRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/turn-state") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/conversations returns badRequest error when model not found")
    func conversationCreateUnknownModel() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let createJSON = #"{"modelRef":"\#(UUID().uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "error")
                #expect((body?["message"] as? String)?.contains("Model not found") == true)
            })
        }
    }

    @Test("POST /api/conversations/copy route is removed")
    func copyConversationRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.POST, "/api/conversations/copy", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"sourceConversationID":"x","modelID":"y"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("DELETE /api/conversations returns notFound for invalid UUID")
    func conversationDeleteInvalidUUID() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.DELETE, "/api/conversations/not-a-uuid") { res async throws in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
            }
        }
    }

    @Test("DELETE /api/conversations returns notFound and error payload when conversation missing")
    func conversationDeleteMissingConversation() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        let missingID = UUID().uuidString

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.DELETE, "/api/conversations/\(missingID)") { res async throws in
                #expect(res.status == .notFound)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.isEmpty == false)
            }
        }
    }

    @Test("GET /api/messages route is removed")
    func listMessagesRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationID = UUID()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let path = "/api/messages?conversationID=\(conversationID.uuidString)"
            try await app.testing().test(.GET, path) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/conversations/:id/messages remains the canonical append route")
    func canonicalAppendInputRouteExists() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "canonical-append-route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: modelProvider)
            try await app.testing().test(.POST, "/api/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.contentType = .json
                // Deliberately invalid body to assert route resolution without invoking stream semantics.
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("POST /api/conversations/:id/append-input alias route is not exposed")
    func appendInputAliasRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.POST, "/api/conversations/\(UUID().uuidString)/append-input", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: #"{"message":"hello"}"#)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/messages/trigger route is removed")
    func triggerAliasRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let body = #"{"conversationID":"invalid","message":"hello"}"#
            try await app.testing().test(.POST, "/api/messages/trigger", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/messages/trigger route is removed")
    func triggerConversationRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let body = #"{"message":"hello","triggerMetadata":{"name":"cron","type":"scheduler"}}"#
            try await app.testing().test(.POST, "/api/conversations/\(UUID().uuidString)/messages/trigger", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/messages route is removed")
    func messagesRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let body = #"{"conversationID":"\#(UUID().uuidString)","message":"hello","imageNames":[]}"#
            try await app.testing().test(.POST, "/api/messages", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("GET /api/conversations/:id/tools returns conversation-scoped tools")
    func conversationToolsRoute() async throws {
        let globalTools = [
            AvailableToolInfo(name: "finish", description: "d", source: .local),
            AvailableToolInfo(name: "Coding Agent", description: "d", source: .a2a),
        ]
        let scopedTools = [AvailableToolInfo(name: "finish", description: "d", source: .local)]
        let conversation = ProtocolOnlyConversationGatewayStub(
            tools: globalTools,
            conversationScopedTools: scopedTools
        )
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)
        let conversationID = UUID()

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/tools") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONDecoder().decode([AvailableToolInfo].self, from: Data(res.body.readableBytesView))
                #expect(payload.map(\.name) == ["finish"])
            }
        }
    }

    @Test("GET /api/conversations/:id/available-tools legacy route is removed")
    func availableToolsLegacyRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/available-tools") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/available-skills route is removed")
    func availableSkillsRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/available-skills") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/tools returns global registry array")
    func toolsRegistryRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/tools") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                #expect(payload is [Any])
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
            }
        }
    }

    @Test("GET /api/conversations/:id/skills returns conversation-scoped skills")
    func conversationSkillsRoute() async throws {
        let globalSkills = [
            AvailableSkillInfo(name: "skill-a", description: "a"),
            AvailableSkillInfo(name: "skill-b", description: "b"),
        ]
        let scopedSkills = [AvailableSkillInfo(name: "skill-a", description: "a")]
        let conversation = ProtocolOnlyConversationGatewayStub(
            skills: globalSkills,
            conversationScopedSkills: scopedSkills
        )
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)
        let conversationID = UUID()

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/conversations/\(conversationID.uuidString)/skills") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONDecoder().decode([AvailableSkillInfo].self, from: Data(res.body.readableBytesView))
                #expect(payload.map(\.name) == ["skill-a"])
            }
        }
    }

    @Test("GET /api/skills returns global registry array")
    func skillsRegistryRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/skills") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                #expect(payload is [Any])
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
            }
        }
    }

    @Test("GET /api/sub-agents returns global registry array")
    func subAgentsRegistryRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/sub-agents") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                #expect(payload is [Any])
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
            }
        }
    }

    @Test("GET /api/modes returns mode profile catalog wrapper")
    func modesRegistryRoute() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub(
            modeProfiles: [
                ModeProfilePickerRow(
                    id: "custom_mode",
                    label: "Custom Mode",
                    description: "Custom profile for API route coverage",
                    symbol: "C"
                )
            ]
        )
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/modes") { res async throws in
                #expect(res.status == .ok)
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
                let payload = try JSONDecoder().decode(ModesCatalogResponse.self, from: Data(res.body.readableBytesView))
                let custom = payload.profiles.first { profile in
                    profile.id == "custom_mode"
                }
                #expect(custom != nil)
                #expect(custom?.label == "Custom Mode")
            }
        }
    }

    @Test("GET /api/tools returns 304 when If-None-Match matches ETag")
    func toolsRegistryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var etag = ""
            try await app.testing().test(.GET, "/api/tools") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/tools", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/skills returns 304 when If-None-Match is wildcard")
    func skillsRegistryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/skills", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: "*")
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/sub-agents returns 304 when If-None-Match matches ETag")
    func subAgentsRegistryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )

            var etag = ""
            try await app.testing().test(.GET, "/api/sub-agents") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/sub-agents", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/modes returns 304 when If-None-Match matches ETag")
    func modesRegistryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [APILayerRESTTestSupport.makeTestModel()])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/modes", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: "*")
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("POST /api/models/query resolves by modelID")
    func modelsQueryRouteResolvesByID() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let body = #"{"modelRef":"\#(model.id.uuidString)"}"#
            try await app.testing().test(.POST, "/api/models/query", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let matches = json?["matches"] as? [[String: Any]]
                #expect((matches?.isEmpty ?? true) == false)
            })
        }
    }

    @Test("POST /api/models/query returns 304 when If-None-Match is wildcard")
    func modelsQueryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let body = #"{"modelRef":"\#(model.id.uuidString)"}"#

            try await app.testing().test(.POST, "/api/models/query", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: "*")
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("GET /api/search serves canonical search")
    func canonicalSearchRouteExists() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.GET, "/api/search?q=abc") { response async throws in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("GET /api/conversations/search is removed")
    func conversationsSearchRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.GET, "/api/conversations/search?q=abc") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("POST /api/conversations/:id/checkpoints/invalidate is removed")
    func checkpointsInvalidateAliasRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/conversations/\(UUID().uuidString)/checkpoints/invalidate") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("POST /api/messages/agent_build/stop is removed")
    func stopAgentBuildAliasRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/messages/agent_build/stop?conversationID=\(UUID().uuidString)") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/events returns backfill shape")
    func conversationEventsBackfillRouteShape() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"events"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (json?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["conversationID"] as? String == cid)
                #expect(json?["latestSeq"] as? Int != nil)
                #expect(json?["lagging"] as? Bool != nil)
                #expect(json?["events"] as? [String] != nil)
            }
        }
    }

    @Test("GET /api/conversations/:id/events returns 304 when If-None-Match matches ETag")
    func conversationEventsBackfillIfNoneMatchReturnsNotModified() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"events-etag"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (json?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            var etag = ""
            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0") { res async throws in
                #expect(res.status == .ok)
                etag = res.headers.first(name: .eTag) ?? ""
                #expect(etag.isEmpty == false)
            }

            try await app.testing().test(.GET, "/api/conversations/\(cid)/events?since=0", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
            }, afterResponse: { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            })
        }
    }

    @Test("POST /api/messages/replay/start route is removed")
    func replayStartRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let body = #"{"conversationID":"\#(UUID().uuidString)","includeTools":true,"includeAgents":true}"#
            try await app.testing().test(.POST, "/api/messages/replay/start", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/messages/replay/stop route is removed")
    func replayStopRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.POST, "/api/messages/replay/stop?conversationID=\(UUID().uuidString)") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/messages/replay/status route is removed")
    func replayStatusRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/messages/replay/status?conversationID=\(UUID().uuidString)") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/upload requires file body")
    func uploadRequiresBody() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.POST, "/api/upload") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/upload requires metadata headers")
    func uploadRequiresHeaders() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.POST, "/api/upload", beforeRequest: { req in
                req.body = .init(data: Data("abc".utf8))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("POST /api/upload succeeds with headers and body")
    func uploadSuccess() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let payload = Data("hello upload".utf8)
            try await app.testing().test(.POST, "/api/upload", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-File-Name", value: "note.txt")
                req.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
                req.body = .init(data: payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect((json?["filename"] as? String)?.contains("note.txt") == true)
                #expect(json?["size"] as? Int == payload.count)
                #expect(json?["contentType"] as? String == "text/plain")
                #expect((json?["filePath"] as? String)?.isEmpty == false)
                #expect(json.map { Set($0.keys) } == Set(["filename", "size", "contentType", "filePath"]))
            })
        }
    }

    @Test("POST /api/conversations/:id/preview-context-compaction returns 404 when route disabled")
    func previewCompactionDisabled() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"s"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/preview-context-compaction", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "tok")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/preview-context-compaction returns 401 when token wrong")
    func previewCompactionBadToken() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"s"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/preview-context-compaction", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "wrong")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("POST /api/conversations/:id/preview-context-compaction returns JSON when authorized (noop under threshold)")
    func previewCompactionSuccessNoop() async throws {
        let preview = ContextCompactionPreviewResult(
            originalMessages: [],
            compactedMessages: nil,
            diagnostics: nil,
            messageProvenance: nil,
            noopReason: "token_threshold_not_met"
        )
        let conversation = ProtocolOnlyConversationGatewayStub(previewContextCompactionResult: preview)
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"s"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })
            try await app.testing().test(.POST, "/api/conversations/\(conversationID)/preview-context-compaction", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                #expect(json?["noopReason"] is String)
            })
        }
    }

    @Test("POST /api/conversations/:id/sub-agents route is removed")
    func spawnSubAgentRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var parentID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"parent-sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                parentID = (body?["conversationID"] as? String) ?? ""
                #expect(parentID.isEmpty == false)
            })
            try await app.testing().test(
                .POST,
                "/api/conversations/\(parentID)/sub-agents",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"mode":"isolated"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test("GET /api/conversations accepts parentConversationID query key")
    func listConversationsAcceptsParentConversationIDQueryKey() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let parentID = UUID()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(
                .GET,
                "/api/conversations?parentConversationID=\(parentID.uuidString)"
            ) { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                #expect(decoded?["items"] is [[String: Any]])
                #expect(decoded?["conversations"] == nil)
            }
        }
    }

    @Test("GET /api/conversations/:id/sub-agents/active lists active sub-agent invocations")
    func listActiveSubAgentInvocations() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "parent-active-list")
        guard let parentID = await runtimeSession.currentConversationID else {
            Issue.record("Expected parent conversation")
            return
        }
        _ = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(context: .isolated, taskDescription: "active child"),
            modelOverride: model
        )
        let api = APILayer(port: 0)
        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .GET,
                "/api/conversations/\(parentID.uuidString)/sub-agents/active",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let data = Data(res.body.readableBytesView)
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let items = payload?["items"] as? [[String: Any]]
                    #expect((items?.isEmpty ?? true) == false)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/sub-agents/:lifecycleID/cancel cancels active invocation")
    func cancelActiveSubAgentInvocation() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "parent-active-cancel")
        guard let parentID = await runtimeSession.currentConversationID else {
            Issue.record("Expected parent conversation")
            return
        }
        _ = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(context: .isolated, taskDescription: "cancel child"),
            modelOverride: model
        )
        let initial = await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiListActiveSubAgentInvocations(parentConversationID: parentID)
        guard let lifecycleID = initial.first?.lifecycleID else {
            Issue.record("Expected active sub-agent lifecycle")
            return
        }
        let api = APILayer(port: 0)
        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(parentID.uuidString)/sub-agents/\(lifecycleID)/cancel",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                }
            )
        }
        let after = await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiListActiveSubAgentInvocations(parentConversationID: parentID)
        #expect(after.isEmpty)
        let lifecycleSnapshot = await runtimeSession.subAgentSpawnService.lifecycleSnapshot(
            conversationID: parentID,
            pathSegments: []
        )
        let cancelled = lifecycleSnapshot.entries.first(where: { $0.lifecycleID == lifecycleID })
        #expect(cancelled?.phase == .failed)
        #expect(cancelled?.error == "cancelled_by_operator")
    }

    @Test("POST /api/conversations/:id/tool-approvals stores resolution and returns 200")
    func resolveToolApprovalRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "tool approval route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let request: [String: Any] = [
            "toolName": "delegate_remote_research",
            "status": "approved",
            "source": "test.rest",
            "reason": "approved in REST coverage"
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )
        }

        let resolution = await runtimeSession.toolApprovalRuntimeService.toolApprovalResolution(
            conversationID: conversationID,
            runID: nil,
            toolName: "delegate_remote_research",
            route: .user
        )
        #expect(resolution?.status == .approved)
        #expect(resolution?.source == "test.rest")
        #expect(resolution?.reason == "approved in REST coverage")
    }

    @Test("POST /api/conversations/:id/tool-approvals returns structured error for invalid id")
    func resolveToolApprovalInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let request: [String: Any] = ["toolName": "delegate_remote_research", "status": "approved"]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(
                .POST,
                "/api/conversations/not-a-uuid/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/tool-approvals returns structured error for invalid body")
    func resolveToolApprovalInvalidBodyReturnsStructuredError() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "tool approval route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                    req.body = .init(string: #"{"status":"approved"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Expected ToolApprovalResolutionRequest JSON body") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/tool-approvals returns structured error for unknown conversation")
    func resolveToolApprovalUnknownConversationReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub(resolveToolApprovalRouteError: .conversationNotFound)
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationID = UUID()
        let request: [String: Any] = ["toolName": "delegate_remote_research", "status": "approved"]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Conversation not found") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/tool-approvals returns 401 when strict tenancy requires bearer token")
    func strictTenancyToolApprovalRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let owner = UUID()
        let api = APILayer(port: 0)
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)
        let auth = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: owner)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"tool approval tenancy"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: auth)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID)/tool-approvals",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"toolName":"delegate_remote_research","status":"approved"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/completion-announcements ingests deduplicated announce")
    func pushCompletionAnnouncementRoute() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "completion route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let revision = try #require(
            await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiGetConversation(id: conversationID)?.controlPlaneRevision
        )
        let ifMatch = APILayer.conversationETag(revision: revision)
        let announceID = UUID()
        let request: [String: Any] = [
            "announceID": announceID.uuidString,
            "delegateHandleID": "handle-1",
            "toolCallID": "tool-call-1",
            "lifecycleID": "handle-1",
            "status": "done",
            "source": "test.rest",
            "toolMessageContent": "delegate complete"
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)
        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: ifMatch)
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws
                    in
                    #expect(res.status == .ok)
                }
            )
            let revisionAfterFirst = try #require(
                await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiGetConversation(id: conversationID)?.controlPlaneRevision
            )
            let ifMatchAfterFirst = APILayer.conversationETag(revision: revisionAfterFirst)
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: ifMatchAfterFirst)
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws
                    in
                    #expect(res.status == .ok)
                }
            )
        }
        let updated = await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiGetConversation(id: conversationID)
        let toolMessages = updated?.messages.filter { $0.role == .tool && $0.toolCallId == "tool-call-1" } ?? []
        #expect(toolMessages.count == 1)
    }

    @Test("POST /api/conversations/:id/completion-announcements returns structured error for invalid id")
    func pushCompletionAnnouncementInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let request: [String: Any] = [
            "delegateHandleID": "handle-1",
            "toolCallID": "tool-call-1",
            "lifecycleID": "handle-1",
            "status": "done",
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            try await app.testing().test(
                .POST,
                "/api/conversations/not-a-uuid/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/completion-announcements returns structured error for invalid body")
    func pushCompletionAnnouncementInvalidBodyReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"completion-route-body"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                    // Missing required `status` field to verify decode failure contract.
                    req.body = .init(string: #"{"delegateHandleID":"h","toolCallID":"t","lifecycleID":"l"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Expected CompletionAnnounceTriggerRequest JSON body") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/completion-announcements returns structured error for unknown conversation")
    func pushCompletionAnnouncementUnknownConversationReturnsStructuredError() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let model = APILayerRESTTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let conversationID = UUID()
        let request: [String: Any] = [
            "delegateHandleID": "handle-1",
            "toolCallID": "tool-call-1",
            "lifecycleID": "handle-1",
            "status": "done",
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID.uuidString)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: body)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Conversation not found") == true)
                }
            )
        }
    }

    @Test("POST /api/conversations/:id/completion-announcements returns 401 when strict tenancy requires bearer token")
    func strictTenancyCompletionAnnounceRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let owner = UUID()
        let api = APILayer(port: 0)
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)
        let auth = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: owner)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"completion tenancy"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: auth)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                conversationID = (body?["conversationID"] as? String) ?? ""
                #expect(conversationID.isEmpty == false)
            })

            try await app.testing().test(
                .POST,
                "/api/conversations/\(conversationID)/completion-announcements",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"delegateHandleID":"h","toolCallID":"t","lifecycleID":"l","status":"done"}"#)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                }
            )
        }
    }

    @Test("Distinct X-SAH-Client-Session headers isolate GET /api/conversations/:id reads")
    func distinctClientSessionsIsolateConversationReads() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        var idA = ""
        var idB = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))

            let createA = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"alpha-session-marker"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionA)
                req.headers.contentType = .json
                req.body = .init(string: createA)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idA = (body?["conversationID"] as? String) ?? ""
                #expect(idA.isEmpty == false)
            })

            let createB = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"beta-session-marker"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
                req.headers.contentType = .json
                req.body = .init(string: createB)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idB = (body?["conversationID"] as? String) ?? ""
                #expect(idB.isEmpty == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(idA)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionA)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]]
                let systemContents = messages?.compactMap { ($0["role"] as? String) == "system" ? ($0["content"] as? String) : nil } ?? []
                #expect(systemContents.contains { $0.contains("alpha-session-marker") })
                #expect(systemContents.contains { $0.contains("beta-session-marker") } == false)
            })

            try await app.testing().test(.GET, "/api/conversations/\(idB)", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]]
                let systemContents = messages?.compactMap { ($0["role"] as? String) == "system" ? ($0["content"] as? String) : nil } ?? []
                #expect(systemContents.contains { $0.contains("beta-session-marker") })
                #expect(systemContents.contains { $0.contains("alpha-session-marker") } == false)
            })
        }
    }

    @Test("GET /api/conversations/:id/orchestration-state stays removed across sessions")
    func distinctClientSessionsOrchestrationStateRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        var idA = ""
        var idB = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )

            let createA = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"orch-alpha"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionA)
                req.headers.contentType = .json
                req.body = .init(string: createA)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idA = (body?["conversationID"] as? String) ?? ""
                #expect(idA.isEmpty == false)
            })

            let createB = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"orch-beta"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
                req.headers.contentType = .json
                req.body = .init(string: createB)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                idB = (body?["conversationID"] as? String) ?? ""
                #expect(idB.isEmpty == false)
            })

            try await app.testing().test(
                .GET,
                "/api/conversations/\(idA)/orchestration-state",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: "X-SAH-Client-Session", value: sessionB)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
        #expect(idA != idB)
    }

    @Test("POST /api/conversations returns 401 when strict tenancy requires bearer token")
    func strictTenancyCreateRequiresOwnerHeader() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Strict tenancy returns 403 when mutating another owner's conversation")
    func strictTenancyPatchForbiddenForWrongOwner() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let ownerA = UUID()
        let ownerB = UUID()
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)
        let authA = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: ownerA)
        let authB = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: ownerB)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authA)
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let bumpJSON = #"{"topic":"cross-tenant"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(cid)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .authorization, value: authB)
                req.body = .init(string: bumpJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("Engine artifact PUT/GET/LIST/DELETE with in-memory harness persistence")
    func engineArtifactsRestRoundTrip() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            try await app.testing().test(.PUT, "/api/conversations/\(cid)/engine-artifacts/demo.bin", beforeRequest: { req in
                req.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                req.body = .init(string: "artifact-bytes")
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.GET, "/api/conversations/\(cid)/engine-artifacts/demo.bin", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let s = String(decoding: Data(res.body.readableBytesView), as: UTF8.self)
                #expect(s == "artifact-bytes")
            })

            try await app.testing().test(.GET, "/api/conversations/\(cid)/engine-artifacts", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                let keys = json?["keys"] as? [String]
                #expect(keys?.contains("demo.bin") == true)
            })

            try await app.testing().test(.DELETE, "/api/conversations/\(cid)/engine-artifacts/demo.bin", beforeRequest: { req in
                req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.GET, "/api/conversations/\(cid)/engine-artifacts/demo.bin", afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/cancel returns 409 run_not_in_flight without active run")
    func conversationCancelWithoutActiveRunReturnsConflict() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
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

    @Test("POST /api/conversations/:id/cancel returns 404 for unknown conversation")
    func conversationCancelMissingConversationReturnsNotFound() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub(cancelRunRouteError: .conversationNotFound)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: StubModelProvider(models: [model])
            )
            let body = #"{"runId":"\#(UUID().uuidString)"}"#
            try await app.testing().test(.POST, "/api/conversations/\(UUID().uuidString)/cancel", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: body)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/cancel accepts missing If-Match and evaluates body-scoped run")
    func conversationCancelStrictModeDoesNotRequireIfMatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"sys"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            let body = #"{"runId":"\#(UUID().uuidString)"}"#
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

    @Test("DELETE /api/conversations/:id returns 428 without If-Match when strict preconditions enabled")
    func conversationDeleteStrictRequiresIfMatch() async throws {
        let container = try APILayerRESTTestSupport.makeContainer()
        let runtimeSession = APILayerRESTTestSupport.makeChatManager(container: container)
        let model = APILayerRESTTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let createJSON = #"{"modelRef":"\#(model.id.uuidString)","userSystemPrompt":"strict-delete"}"#
            var cid = ""
            try await app.testing().test(.POST, "/api/conversations", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: createJSON)
            }, afterResponse: { res async throws in
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                cid = (body?["conversationID"] as? String) ?? ""
                #expect(cid.isEmpty == false)
            })

            try await app.testing().test(.DELETE, "/api/conversations/\(cid)", afterResponse: { res async throws in
                #expect(res.status == .preconditionRequired)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["error"] as? String == "precondition_required")
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns 409 mode_change_run_in_progress when run is active")
    func conversationPatchReturnsRunConflictWhenModeChangeRunActive() async throws {
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationID = UUID()
        let conversation = ModelConversation(
            id: conversationID,
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let activeRunID = UUID()
        let conversationStub = ModePatchConflictConversationStub(
            conversation: conversation,
            activeRunID: activeRunID
        )
        let runtimeStub = ModePatchConflictRuntimeStub()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversationStub,
                runtime: runtimeStub,
                modelProvider: StubModelProvider(models: [model])
            )
            let updateJSON = #"{"expectedRevision":1,"modeProfileID":"custom.profile.conflict"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(conversationID.uuidString)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["code"] as? String == ConversationRunConflictBody.modeChangeRunInProgressCode)
                #expect(body?["conversationID"] as? String == conversationID.uuidString)
                #expect(body?["activeRunID"] as? String == activeRunID.uuidString)
            })
        }
    }

    @Test("PATCH /api/conversations/:id returns 409 model_or_prompt_change_run_in_progress when run is active")
    func conversationPatchReturnsRunConflictWhenModelChangeRunActive() async throws {
        let model = APILayerRESTTestSupport.makeTestModel()
        let alternateModel = APILayerRESTTestSupport.makeTestModel()
        let conversationID = UUID()
        let conversation = ModelConversation(
            id: conversationID,
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let activeRunID = UUID()
        let conversationStub = ModelPromptPatchConflictConversationStub(
            conversation: conversation,
            activeRunID: activeRunID
        )
        let runtimeStub = ModePatchConflictRuntimeStub()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversationStub,
                runtime: runtimeStub,
                modelProvider: StubModelProvider(models: [model, alternateModel])
            )
            let updateJSON = #"{"expectedRevision":1,"modelRef":"\#(alternateModel.id.uuidString)"}"#
            try await app.testing().test(.PATCH, "/api/conversations/\(conversationID.uuidString)", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.body = .init(string: updateJSON)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["code"] as? String == ConversationRunConflictBody.modelOrPromptChangeRunInProgressCode)
                #expect(body?["conversationID"] as? String == conversationID.uuidString)
                #expect(body?["activeRunID"] as? String == activeRunID.uuidString)
            })
        }
    }

    @Test("POST /api/approvals/:id resolves on the unified decision vocabulary")
    func unifiedApprovalResolveAllowAlways() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        let grants = InMemoryExecApprovalGrantStore()
        await ExecApprovalStore.shared.configure(grantStore: grants)
        defer { Task { await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore()) } }
        let conversationID = UUID()
        await ExecApprovalStore.shared.registerPending(
            id: "unified-1",
            command: "git push origin main",
            scope: ExecApprovalScope(conversationID: conversationID, ownerAccountID: nil)
        )

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(
                .POST,
                "/api/approvals/unified-1",
                beforeRequest: { req in
                    try req.content.encode(["decision": "allowAlways"])
                }
            ) { res async throws in
                #expect(res.status == .ok)
            }
            #expect(await ExecApprovalStore.shared.isDurableApproved(command: "git status"))
        }
    }

    @Test("POST /api/approvals/:id returns 403 for cross-tenant resolve under strict tenancy")
    func unifiedApprovalResolveCrossTenantForbidden() async throws {
        let ownerA = UUID()
        let ownerB = UUID()
        let conversationID = UUID()
        let model = APILayerRESTTestSupport.makeTestModel()
        let conversationRow = ModelConversation(
            id: conversationID,
            model: model,
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            topic: "exec-approval-tenancy",
            description: nil,
            interactionMode: .chat,
            metadata: nil,
            ownerAccountID: ownerA,
            lineageKind: .root,
            origin: .user
        )
        let conversation = ProtocolOnlyConversationGatewayStub(
            conversationsByID: [conversationID: conversationRow]
        )
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [model])
        let api = APILayer(port: 0)
        await APILayerRESTTestSupport.configureStrictTenancyAuth(on: api)
        let authB = try await APILayerRESTTestSupport.bearerAuthorization(ownerAccountID: ownerB)
        await ExecApprovalStore.shared.registerPending(
            id: "cross-tenant-1",
            command: "git push origin main",
            scope: ExecApprovalScope(conversationID: conversationID, ownerAccountID: ownerA)
        )
        defer {
            Task {
                _ = await ExecApprovalStore.shared.resolve(
                    id: "cross-tenant-1",
                    scope: ExecApprovalScope(conversationID: conversationID, ownerAccountID: ownerA),
                    strictTenancy: true,
                    ownerScope: ownerA,
                    approved: false,
                    reason: "test cleanup"
                )
            }
        }

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(
                .POST,
                "/api/approvals/cross-tenant-1",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .authorization, value: authB)
                    try req.content.encode(["decision": "allowAlways"])
                }
            ) { res async throws in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("POST /api/approvals/:id returns 404 for unknown approval")
    func unifiedApprovalResolveUnknown() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(
                .POST,
                "/api/approvals/missing-id",
                beforeRequest: { req in
                    try req.content.encode(["decision": "deny"])
                }
            ) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/exec-approvals/grants returns sorted command names")
    func execApprovalGrantsList() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        await ExecApprovalStore.shared.configure(
            grantStore: InMemoryExecApprovalGrantStore(commandNames: ["grep", "git"])
        )
        defer { Task { await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore()) } }

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.GET, "/api/exec-approvals/grants") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["commandNames"] as? [String] == ["git", "grep"])
            }
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName removes an existing grant")
    func execApprovalGrantsRevoke() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        await ExecApprovalStore.shared.configure(
            grantStore: InMemoryExecApprovalGrantStore(commandNames: ["git", "npm"])
        )
        defer { Task { await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore()) } }

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.DELETE, "/api/exec-approvals/grants/git") { res async throws in
                #expect(res.status == .ok)
            }
            #expect(await ExecApprovalStore.shared.listDurableGrants() == ["npm"])
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName accepts percent-encoded names")
    func execApprovalGrantsRevokePercentEncoded() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        await ExecApprovalStore.shared.configure(
            grantStore: InMemoryExecApprovalGrantStore(commandNames: ["git status"])
        )
        defer { Task { await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore()) } }

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.DELETE, "/api/exec-approvals/grants/git%20status") { res async throws in
                #expect(res.status == .ok)
            }
            #expect(await ExecApprovalStore.shared.listDurableGrants() == [])
        }
    }

    @Test("DELETE /api/exec-approvals/grants/:commandName returns 404 for unknown grant")
    func execApprovalGrantsRevokeNotFound() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)
        await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore())
        defer { Task { await ExecApprovalStore.shared.configure(grantStore: InMemoryExecApprovalGrantStore()) } }

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            try await app.testing().test(.DELETE, "/api/exec-approvals/grants/missing") { res async throws in
                #expect(res.status == .notFound)
                let body = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(body?["type"] as? String == "error")
                #expect(body?["message"] as? String == "Exec approval grant not found")
            }
        }
    }

    @Test("Static exec-approvals grants routes register before :id")
    func execApprovalGrantsRoutesRegisteredBeforeID() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            func pathDescription(_ route: Route) -> String {
                route.path.map { component in
                    switch component {
                    case .constant(let value): return value
                    case .parameter(let name): return ":\(name)"
                    case .anything: return "*"
                    case .catchall: return "**"
                    }
                }.joined(separator: "/")
            }
            let execApprovalRoutes = app.routes.all.filter { route in
                pathDescription(route).hasPrefix("api/exec-approvals")
            }
            let grantsGetIndex = execApprovalRoutes.firstIndex { route in
                route.method == .GET && pathDescription(route) == "api/exec-approvals/grants"
            }
            let grantsDeleteIndex = execApprovalRoutes.firstIndex { route in
                route.method == .DELETE && pathDescription(route) == "api/exec-approvals/grants/:commandName"
            }
            let postIDIndex = execApprovalRoutes.firstIndex { route in
                route.method == .POST && pathDescription(route) == "api/exec-approvals/:id"
            }
            #expect(grantsGetIndex != nil)
            #expect(grantsDeleteIndex != nil)
            #expect(postIDIndex != nil)
            if let grantsGetIndex, let grantsDeleteIndex, let postIDIndex {
                #expect(grantsGetIndex < postIDIndex)
                #expect(grantsDeleteIndex < postIDIndex)
            }
        }
    }
}

private final class ModePatchConflictConversationStub: APILayerConversationManaging, Sendable {
    private let baseConversation: ModelConversation
    private let activeRunID: UUID

    init(conversation: ModelConversation, activeRunID: UUID) {
        self.baseConversation = conversation
        self.activeRunID = activeRunID
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        [baseConversation]
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        []
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        _ = (conversationID, routingPolicyTools)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        _ = (conversationID, routingPolicySkills)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        _ = (conversationID, thinkingConfig)
        throw APILayerConversationAPIError.unsupported
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        _ = (conversationID, hard)
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        guard id == baseConversation.id else { return nil }
        return baseConversation
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        _ = patch
        _ = resolvedModel
        throw ConversationServiceError.conversationModeChangeRunInProgress(
            conversationID: conversationID,
            activeRunID: activeRunID
        )
    }
}

private final class ModelPromptPatchConflictConversationStub: APILayerConversationManaging, Sendable {
    private let baseConversation: ModelConversation
    private let activeRunID: UUID

    init(conversation: ModelConversation, activeRunID: UUID) {
        self.baseConversation = conversation
        self.activeRunID = activeRunID
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        [baseConversation]
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        []
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        _ = (conversationID, routingPolicyTools)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        _ = (conversationID, routingPolicySkills)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        _ = (conversationID, thinkingConfig)
        throw APILayerConversationAPIError.unsupported
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        _ = (conversationID, hard)
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        guard id == baseConversation.id else { return nil }
        return baseConversation
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        _ = patch
        _ = resolvedModel
        throw ConversationServiceError.conversationModelOrPromptChangeRunInProgress(
            conversationID: conversationID,
            activeRunID: activeRunID
        )
    }
}

private final class ModePatchConflictRuntimeStub: APILayerChatRuntimeManaging, Sendable {
    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        systemReminder: String?,
        originSurface: String?,
        originSenderID: String?
    ) async throws -> ChatStreamResponse {
        _ = (
            conversationID,
            text,
            images,
            enableTools,
            enableAgents,
            expectedPreviousTailHarnessMessageID,
            inputTrustRaw,
            systemReminder,
            originSurface,
            originSenderID
        )
        throw APILayerConversationAPIError.unsupported
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        _ = (id, push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        _ = id
    }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
        throw APILayerConversationAPIError.unsupported
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        _ = (conversationID, filter)
        return ConversationRunListResponse(runs: [])
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        _ = (conversationID, runID, includeProjectionDetail)
        return nil
    }
}
