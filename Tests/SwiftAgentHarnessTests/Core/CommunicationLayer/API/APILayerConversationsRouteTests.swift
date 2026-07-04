import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer conversations routes")
struct APILayerConversationsRouteTests {
    @Test("Conversation create/read/delete routes complete with valid IDs")
    func conversationLifecycleRoutes() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))

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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))

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

    @Test("PATCH /api/conversations/:id returns structured error for invalid ID")
    func conversationPatchInvalidIDReturnsStructuredError() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("GET /api/conversations/:id returns 304 when If-None-Match matches ETag")
    func conversationGetIfNoneMatchReturnsNotModified() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))

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

    @Test("GET /api/conversations/:id returns conversation listed in catalog when registry was cleared")
    func conversationGetHydratesFromCatalogAfterRegistryCleared() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let conversationID = try await runtimeSession.createConversation(with: model, userSystemPrompt: "catalog-get-hydrate")
        await runtimeSession.evictRegistryForTesting()
        #expect(await runtimeSession.listConversationInfo().isEmpty)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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

    @Test("GET /api/conversations/:id returns notFound for invalid UUID")
    func conversationGetInvalidUUID() async throws {
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
            try await app.testing().test(.GET, "/api/conversations/not-a-uuid") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id returns notFound for non-existent conversation")
    func conversationGetNotFound() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "get-test", topic: "Test topic", description: "Test description")
        let convID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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

    @Test("GET /api/conversations/:id/orchestration-state route is removed")
    func conversationOrchestrationStateRouteRemoved() async throws {
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
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/orchestration-state") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations/:id/turn-state route is removed")
    func conversationTurnStateRouteRemoved() async throws {
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
            try await app.testing().test(.GET, "/api/conversations/\(UUID().uuidString)/turn-state") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("POST /api/conversations returns badRequest error when model not found")
    func conversationCreateUnknownModel() async throws {
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let conversationID = UUID()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "canonical-append-route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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

    @Test("GET /api/modes returns 304 when If-None-Match matches ETag")
    func modesRegistryIfNoneMatchReturnsNotModified() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [APILayerRESTRouteTestSupport.makeTestModel()])
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

    @Test("GET /api/conversations/search is removed")
    func conversationsSearchRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            try await app.testing().test(.GET, "/api/conversations/search?q=abc") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("POST /api/messages/agent_build/stop is removed")
    func stopAgentBuildAliasRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
            )
            try await app.testing().test(.POST, "/api/messages/agent_build/stop?conversationID=\(UUID().uuidString)") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("POST /api/messages/replay/start route is removed")
    func replayStartRouteRemoved() async throws {
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
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
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

    @Test("POST /api/conversations/:id/tool-approvals stores resolution and returns 200")
    func resolveToolApprovalRoute() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
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
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let request: [String: Any] = ["toolName": "delegate_remote_research", "status": "approved"]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "tool approval route")
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let conversationID = UUID()
        let request: [String: Any] = ["toolName": "delegate_remote_research", "status": "approved"]
        let body = try JSONSerialization.data(withJSONObject: request)
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

    @Test("POST /api/conversations/:id/completion-announcements ingests deduplicated announce")
    func pushCompletionAnnouncementRoute() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
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
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
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
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var conversationID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
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
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("GET /api/conversations/:id/orchestration-state stays removed across sessions")
    func distinctClientSessionsOrchestrationStateRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
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
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

    @Test("Engine artifact PUT/GET/LIST/DELETE with in-memory harness persistence")
    func engineArtifactsRestRoundTrip() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("POST /api/conversations/:id/cancel returns 404 for unknown conversation")
    func conversationCancelMissingConversationReturnsNotFound() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub(cancelRunRouteError: .conversationNotFound)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        await api.setHTTPPreconditionPolicySettings(.init(strictMode: true))

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("PATCH /api/conversations/:id returns 409 mode_change_run_in_progress when run is active")
    func conversationPatchReturnsRunConflictWhenModeChangeRunActive() async throws {
        let model = APILayerRESTRouteTestSupport.makeTestModel()
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
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let alternateModel = APILayerRESTRouteTestSupport.makeTestModel()
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
                modelProvider: APILayerRESTStubModelProvider(models: [model, alternateModel])
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

}
