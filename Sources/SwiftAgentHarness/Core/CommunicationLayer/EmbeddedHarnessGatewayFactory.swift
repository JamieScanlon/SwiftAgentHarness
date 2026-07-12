import Foundation

enum EmbeddedHarnessGatewayFactory {
    static func makeGatewayServices(
        services: HarnessRuntimeSessionFactory.Services
    ) -> APILayerChatGatewayServices {
        let subAgentIngress = SubAgentAPIIngressService(
            spawn: services.subAgentSpawnService,
            completion: services.subAgentCompletionRuntimeService
        )
        let runtimeGraph = SplitGatewayServiceFactory.makeRuntimeGraph(
            services: services,
            subAgentLifecycleHost: subAgentIngress,
            subAgentCompletionHost: subAgentIngress,
            subAgentCompletion: SubAgentCompletionIngressService(host: subAgentIngress)
        )
        return SplitGatewayServiceFactory.makeServiceGraph(runtimeGraph: runtimeGraph).gatewayServices
    }

    static func makeCommunicationLayer() -> CommunicationLayer {
        CommunicationLayer(
            modelPoolTopics: ModelStateTopicHub(),
            conversationEvents: ConversationEventsTopicHub(),
            conversationState: ConversationStateTopicHub(),
            traceTopics: TraceTopicHub(),
            subAgentLifecycle: SubAgentLifecycleTopicHub(),
            capabilityRegistries: CapabilityRegistryTopicHub(),
            conversationsRegistry: ConversationsRegistryTopicHub()
        )
    }
}
