import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer sub-agents routes")
struct APILayerSubAgentsRouteTests {
    @Test("GET /api/sub-agents returns global registry array")
    func subAgentsRegistryRoute() async throws {
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
            try await app.testing().test(.GET, "/api/sub-agents") { res async throws in
                #expect(res.status == .ok)
                let payload = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                #expect(payload is [Any])
                #expect((res.headers.first(name: .eTag) ?? "").isEmpty == false)
            }
        }
    }

    @Test("GET /api/sub-agents returns 304 when If-None-Match matches ETag")
    func subAgentsRegistryIfNoneMatchReturnsNotModified() async throws {
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

    @Test("POST /api/conversations/:id/sub-agents route is removed")
    func spawnSubAgentRouteRemoved() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)
        var parentID = ""

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

    @Test("GET /api/conversations/:id/sub-agents/active lists active sub-agent invocations")
    func listActiveSubAgentInvocations() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
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
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
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
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
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

    @Test("POST cancel with unknown lifecycle id returns typed error envelope")
    func cancelUnknownLifecycleIDReturnsErrorEnvelope() async throws {
        let container = try APILayerRESTRouteTestSupport.makeContainer()
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let runtimeSession = APILayerRESTRouteTestSupport.makeChatManager(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "parent-cancel-missing")
        guard let parentID = await runtimeSession.currentConversationID else {
            Issue.record("Expected parent conversation")
            return
        }
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: APILayerRESTStubModelProvider(models: [model]))
            try await app.testing().test(
                .POST,
                "/api/conversations/\(parentID.uuidString)/sub-agents/missing-lifecycle-id/cancel",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: .ifMatch, value: "\"conv-v1\"")
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                    let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                    #expect(json?["type"] as? String == "error")
                    #expect((json?["message"] as? String)?.contains("Sub-agent invocation not found") == true)
                }
            )
        }
    }

}
