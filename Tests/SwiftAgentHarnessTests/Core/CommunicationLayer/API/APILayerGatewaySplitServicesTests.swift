import Foundation
import Logging
import SwiftAgentKit
import Testing
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
}
