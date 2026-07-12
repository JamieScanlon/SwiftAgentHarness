import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

/// Tests for `POST /api/conversations/:id/compact` (manual context compaction REST endpoint).
///
/// The endpoint:
///   - is gated by `contextCompaction.manualRESTEnabled` in `PromptConfig.json`
///   - reuses the preview-API token for auth (`X-SAH-Context-Compaction-Preview-Token`)
///   - persists a checkpoint + cooldown when it actually compacts (asserted indirectly via the
///     `persisted` flag in the JSON body)
///   - returns 404 for unknown ids, 401 for bad token, 403 if no token is configured, 404
///     when the route itself is disabled.
private final class StubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    init(models: [Model] = []) { self.models = models }
    func getAvailableModels() async -> [Model] { models }
}

private enum ManualCompactRestSupport {
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

    static func transformConfig(manualRESTEnabled: Bool) -> ConversationTransformConfiguration {
        let cc = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "summarizer:test",
            manualToolEnabled: true,
            manualSlashEnabled: true,
            manualRESTEnabled: manualRESTEnabled
        )
        return ConversationTransformConfiguration(
            chat: .allEnabled,
            plan: .allEnabled,
            agent: .allEnabled,
            transformTimeoutSeconds: 1800,
            contextCompaction: cc
        )
    }
}

@Suite("APILayer manual context compaction REST", .serialized)
struct APILayerManualCompactRestTests {

    @Test("POST /api/conversations/:id/compact returns 404 when manualRESTEnabled is false")
    func returns404WhenDisabled() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: false)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        guard let cid = await runtimeSession.currentConversationID else {
            Issue.record("Expected conversation")
            return
        }
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/\(cid.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact returns 403 when manualRESTEnabled is true but no preview token configured")
    func returns403WhenNoToken() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        guard let cid = await runtimeSession.currentConversationID else {
            Issue.record("Expected conversation")
            return
        }
        let api = APILayer(port: 0)
        // No `setContextCompactionPreviewSettings` call → authToken == nil → 403.

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/\(cid.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "any")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.isEmpty == false)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact returns 401 when token mismatches")
    func returns401OnBadToken() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        guard let cid = await runtimeSession.currentConversationID else {
            Issue.record("Expected conversation")
            return
        }
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/\(cid.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "wrong")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.isEmpty == false)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact returns 400 when the URL id is not a valid UUID")
    func returns400OnBadUUID() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/not-a-uuid/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["type"] as? String == "error")
                #expect((json?["message"] as? String)?.contains("Invalid conversation ID") == true)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact returns 404 when conversation id is unknown")
    func returns404OnUnknownConversation() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            let randomID = UUID()
            try await app.testing().test(.POST, "/api/conversations/\(randomID.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact returns documented JSON shape when authorized")
    func returnsDocumentedJSONShapeWhenAuthorized() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        // Manual REST/Slash/Tool all bypass the proactive threshold gate via
        // `ignoreTokenThreshold: true` (see `performManualCompaction`), so even a short
        // conversation produces a transform pass — under the default `NoOpConversationTransformer`
        // injected by `HarnessRuntimeSession.init(container:...)` that pass returns the messages unchanged
        // with `diagnostics == nil`, so `persisted` is `false` and `compactedMessages` echoes
        // the input. This test asserts the endpoint contract (status, content type, fields)
        // without depending on any LLM behaviour.
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        guard let cid = await runtimeSession.currentConversationID else {
            Issue.record("Expected conversation")
            return
        }
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/\(cid.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.headers.contentType = .json
                req.body = .init(string: "{\"reason\":\"manual REST test\"}")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let data = Data(res.body.readableBytesView)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                // Documented fields must always be present and well-typed.
                #expect(json?["persisted"] is Bool)
                #expect(json?["promptTokens"] is Int)
                #expect(json?["thresholdTokens"] is Int)
                #expect(json?["originalMessages"] is [Any])
                // Under the NoOp transformer, the route does NOT mark the result as a checkpoint:
                // diagnostics != "context_compacted" → persisted == false.
                #expect((json?["persisted"] as? Bool) == false)
            })
        }
    }

    @Test("POST /api/conversations/:id/compact accepts an empty body and uses default (nil) reason")
    func acceptsEmptyBody() async throws {
        let container = try ManualCompactRestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            conversationTransformConfiguration: ManualCompactRestSupport.transformConfig(manualRESTEnabled: true)
        )
        let model = ManualCompactRestSupport.makeTestModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s")
        guard let cid = await runtimeSession.currentConversationID else {
            Issue.record("Expected conversation")
            return
        }
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(
            ContextCompactionPreviewAPISettings(isRouteEnabled: true, authToken: "secret")
        )

        try await withApp { app in
            await api.configureRoutesForTesting(app: app, runtimeSession: runtimeSession, modelProvider: StubModelProvider(models: [model]))
            try await app.testing().test(.POST, "/api/conversations/\(cid.uuidString)/compact", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-SAH-Context-Compaction-Preview-Token", value: "secret")
                req.headers.replaceOrAdd(name: .ifMatch, value: "*")
                req.headers.contentType = .json
                req.body = .init(string: "{}")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }
}
