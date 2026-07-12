import Foundation
import SwiftAgentKit
import SwiftData

private final class EmbeddedHarnessModelProvider: APILayerModelManaging, @unchecked Sendable {
    let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] {
        models
    }
}

/// Composition root for embedded CLI / in-process hosts: subscribe on ``CommunicationLayer``, mutate on ``EmbeddedHarnessAPIClient``.
public struct EmbeddedHarnessHost: Sendable {
    public let runtimeSession: HarnessRuntimeSession
    public let communicationLayer: CommunicationLayer
    public let apiLayer: APILayer
    public let apiClient: EmbeddedHarnessAPIClient
    public var defaultSession: EmbeddedHarnessAPISession

    private init(
        runtimeSession: HarnessRuntimeSession,
        communicationLayer: CommunicationLayer,
        apiLayer: APILayer,
        apiClient: EmbeddedHarnessAPIClient,
        defaultSession: EmbeddedHarnessAPISession
    ) {
        self.runtimeSession = runtimeSession
        self.communicationLayer = communicationLayer
        self.apiLayer = apiLayer
        self.apiClient = apiClient
        self.defaultSession = defaultSession
    }

    public static func makeForTesting(
        container: ModelContainer,
        model: Model,
        sessionNamespace: UUID = UUID(),
        tenancyPolicy: TenancyPolicySettings = .disabled,
        httpPreconditions: HTTPPreconditionPolicySettings = .disabled,
        authorizationHeader: String? = nil
    ) async throws -> EmbeddedHarnessHost {
        let runtimeSession = HarnessRuntimeSession(container: container)
        let communicationLayer = EmbeddedHarnessGatewayFactory.makeCommunicationLayer()
        await runtimeSession.setConversationTopicPublisher(communicationLayer)
        await runtimeSession.setTraceTopicPublisher(communicationLayer)
        await runtimeSession.setSubAgentLifecyclePublisher(communicationLayer)

        let services = await runtimeSession.services
        let gateway = EmbeddedHarnessGatewayFactory.makeGatewayServices(services: services)
        let apiLayer = APILayer(port: 0)
        await apiLayer.setChatGatewayServices(gateway)
        await apiLayer.setModelProvider(EmbeddedHarnessModelProvider(models: [model]))
        await apiLayer.setTenancyPolicySettings(tenancyPolicy)
        await apiLayer.setHTTPPreconditionPolicySettings(httpPreconditions)
        if tenancyPolicy.requireAuthenticatedOwnerOnMutations {
            await apiLayer.setAPIAccessTokenAuthenticationSettings(
                APIAccessTokenAuthenticationSettings(hs256Secret: "embedded-host-test-secret")
            )
        }
        await apiLayer.setCommunicationWireResources(
            layer: communicationLayer,
            coordinator: await runtimeSession.wireModelInvocationCoordinator
        )

        let app = try await apiLayer.makeEmbeddedApplication()
        let apiClient = EmbeddedHarnessAPIClient(app: app)
        await HarnessMutationTransportHolder.shared.setTransport(apiClient)

        return EmbeddedHarnessHost(
            runtimeSession: runtimeSession,
            communicationLayer: communicationLayer,
            apiLayer: apiLayer,
            apiClient: apiClient,
            defaultSession: EmbeddedHarnessAPISession(
                connectionNamespace: sessionNamespace,
                authorizationHeader: authorizationHeader
            )
        )
    }

    public func shutdown() async throws {
        await HarnessMutationTransportHolder.shared.setTransport(nil)
        try await apiClient.shutdown()
    }
}
