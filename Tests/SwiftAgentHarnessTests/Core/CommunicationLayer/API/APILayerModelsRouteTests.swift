import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("APILayer models routes")
struct APILayerModelsRouteTests {
    @Test("GET /api/models returns empty models on provider error")
    func listModelsFallbackOnError() async throws {
        enum TestError: Error { case boom }
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = APILayerRESTStubModelProvider(models: [], error: TestError.boom)
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let modelProvider = APILayerRESTStubModelProvider(models: [model])
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

    @Test("POST /api/models/query resolves by modelID")
    func modelsQueryRouteResolvesByID() async throws {
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
        let model = APILayerRESTRouteTestSupport.makeTestModel()
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: APILayerRESTStubModelProvider(models: [model])
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

}
