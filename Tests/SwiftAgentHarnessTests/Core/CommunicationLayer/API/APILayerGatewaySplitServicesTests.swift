import Foundation
import Logging
import SwiftAgentKit
import Testing
import VaporTesting
@testable import SwiftAgentHarness

private final class SplitGatewayStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    init(models: [Model]) { self.models = models }
    func getAvailableModels() async -> [Model] { models }
}

/// Split gateway instances for conversation vs runtime protocols.
/// Static `@Test` methods live on an `enum` to avoid a Swift 6 compiler crash when combining `@Suite struct`, `#expect`, and opened existential protocol values (see SR-like “Invalid conformance in type-checked AST”).
enum APILayerGatewaySplitServicesTests {
    @Test
    static func splitWrappersAreDistinctObjects() async {
        let gateway = APILayerChatGatewayServices(
            conversation: ConversationSessionService(backend: ProtocolOnlyConversationGatewayStub()),
            runtime: ChatRuntimeService(backend: ProtocolOnlyRuntimeGatewayStub())
        )
        let conversation = gateway.conversation as AnyObject
        let runtime = gateway.runtime as AnyObject
        #expect(ObjectIdentifier(conversation) != ObjectIdentifier(runtime))
    }

    @Test
    static func configureChatGatewayAcceptsIndependentProtocolOnlyInstances() async {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        #expect(ObjectIdentifier(conversation) != ObjectIdentifier(runtime))
        let gateway = APILayerChatGatewayServices(conversation: conversation, runtime: runtime)
        #expect(ObjectIdentifier(gateway.conversation as AnyObject) == ObjectIdentifier(conversation))
        #expect(ObjectIdentifier(gateway.runtime as AnyObject) == ObjectIdentifier(runtime))
    }

    @Test
    static func routeDependenciesPreserveSplitInstances() {
        let gateway = APILayerChatGatewayServices(
            conversation: ConversationSessionService(backend: ProtocolOnlyConversationGatewayStub()),
            runtime: ChatRuntimeService(backend: ProtocolOnlyRuntimeGatewayStub())
        )
        let conversation = gateway.conversation as AnyObject
        let runtime = gateway.runtime as AnyObject
        let deps = APILayerRouteDependencies(
            gateway: gateway,
            modelManager: SplitGatewayStubModelProvider(models: []),
            logger: Logger(label: "test"),
            oauthCallbackDelivery: nil,
            contextCompactionPreview: .disabled
        )
        #expect(ObjectIdentifier(deps.conversation as AnyObject) == ObjectIdentifier(conversation))
        #expect(ObjectIdentifier(deps.runtime as AnyObject) == ObjectIdentifier(runtime))
    }

    @Test
    static func explicitGatewayWiringServesRESTStatus() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let api = APILayer(port: 0)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(SplitGatewayStubModelProvider(models: []))
        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: SplitGatewayStubModelProvider(models: [])
            )
            try await app.testing().test(.GET, "/api/status") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect(json?["status"] as? String == "running")
                #expect(json?["sessions"] as? Int == 0)
            }
        }
    }

    @Test
    static func traceFetchRouteReturnsConversationTracePayload() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let conversationID = UUID()
        let api = APILayer(port: 0)
        await api.setChatGatewayServices(APILayerChatGatewayServices(conversation: conversation, runtime: runtime))
        await api.setModelProvider(SplitGatewayStubModelProvider(models: []))
        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: SplitGatewayStubModelProvider(models: [])
            )
            try await app.testing().test(.GET, "/api/traces/\(conversationID.uuidString)") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any]
                #expect((json?["conversationID"] as? String)?.lowercased() == conversationID.uuidString.lowercased())
                let spans = json?["spans"] as? [Any]
                #expect(spans?.isEmpty == true)
            }
        }
    }
}
