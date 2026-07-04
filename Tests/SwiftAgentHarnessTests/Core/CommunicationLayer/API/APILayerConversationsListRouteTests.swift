import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer conversations list routes")
struct APILayerConversationsListRouteTests {
    @Test("GET /api/conversations paged list auto-scopes to bearer owner under strict tenancy")
    func strictTenancyPagedListAutoScopesToBearerOwner() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        let ownerA = UUID()
        let ownerB = UUID()
        await APILayerRESTRouteTestSupport.configureStrictTenancyAuth(on: api)
        let authA = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: ownerA)
        let authB = try await APILayerRESTRouteTestSupport.bearerAuthorization(ownerAccountID: ownerB)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("GET /api/conversations/select/:id returns notFound (route removed)")
    func conversationSelectRouteRemoved() async throws {
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
            try await app.testing().test(.GET, "/api/conversations/select/not-a-uuid") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/conversations returns paged summary shape")
    func conversationListRoute() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test")
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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

    @Test("GET /api/conversations with limit/offset query returns paged summary shape")
    func conversationListRouteWithQueryParameters() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test-query")
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-test-trailing-slash")
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let conversationID = try await runtimeSession.createConversation(with: model, userSystemPrompt: "list-soft-delete-test")
        try await runtimeSession.deleteConversation(conversationID: conversationID, hard: false)
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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
        let modelProvider = APILayerRESTStubModelProvider(models: [])
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

    @Test("GET /api/search serves canonical search")
    func canonicalSearchRouteExists() async throws {
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
            try await app.testing().test(.GET, "/api/search?q=abc") { response async throws in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("GET /api/conversations accepts parentConversationID query key")
    func listConversationsAcceptsParentConversationIDQueryKey() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let parentID = UUID()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

}
