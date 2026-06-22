import Foundation

/// Explicit runtime + domain services wired at the composition root (no monolithic gateway owner).
public struct HarnessRuntimeGraph {
    let conversationDomain: ConversationDomainServiceBundle
    let agentRuntime: AgentRuntimeSessionService
    let conversationReplay: ConversationReplayService
    let toolPolicyOwner: any ConversationToolModePolicyOwning
    let subAgentLifecycleHost: any SubAgentLifecycleOrchestrationHosting
    let subAgentCompletionHost: any SubAgentCompletionIngressHosting
    let subAgentCompletion: any SubAgentCompletionIngressServicing
}

/// Explicit gateway service instances built without a monolithic host owner.
public struct HarnessServiceGraph {
    let catalog: any ConversationCatalogServicing
    let controlPlane: any ConversationControlPlaneServicing
    let lifecycle: any ConversationLifecycleServicing
    let runsReplay: any ConversationRunsReplayServicing
    let harnessUtility: any ConversationHarnessUtilityServicing
    let residualAPI: any ConversationResidualAPIServicing
    let policy: any ConversationToolModePolicyServicing
    let subAgentLifecycle: any SubAgentLifecycleOrchestrationServicing
    let subAgentCompletion: any SubAgentCompletionIngressServicing
    let runtime: any APILayerChatRuntimeManaging

    var conversationAdapter: APILayerConversationAdapter {
        APILayerConversationAdapter(
            catalog: catalog,
            controlPlane: controlPlane,
            lifecycle: lifecycle,
            runsReplay: runsReplay,
            harnessUtility: harnessUtility,
            residualAPI: residualAPI,
            policy: policy,
            subAgentLifecycle: subAgentLifecycle,
            subAgentCompletion: subAgentCompletion
        )
    }

    var gatewayServices: APILayerChatGatewayServices {
        APILayerChatGatewayServices(
            conversation: ConversationSessionService(backend: conversationAdapter),
            runtime: ChatRuntimeService(backend: runtime)
        )
    }
}

public enum SplitGatewayServiceFactory {
    public static func makeServiceGraph(
        graph: HarnessServiceGraph
    ) -> APILayerChatGatewayServices {
        graph.gatewayServices
    }

    public static func makeServiceGraph(
        runtimeGraph: HarnessRuntimeGraph,
        runtime: (any APILayerChatRuntimeManaging)? = nil
    ) -> HarnessServiceGraph {
        HarnessServiceGraph(
            catalog: runtimeGraph.conversationDomain.catalog,
            controlPlane: runtimeGraph.conversationDomain.controlPlane,
            lifecycle: runtimeGraph.conversationDomain.lifecycle,
            runsReplay: runtimeGraph.conversationDomain.runsReplay,
            harnessUtility: runtimeGraph.conversationDomain.harnessUtility,
            residualAPI: runtimeGraph.conversationDomain.residualAPI,
            policy: ConversationToolModePolicyService(owner: runtimeGraph.toolPolicyOwner),
            subAgentLifecycle: SubAgentLifecycleOrchestrationService(host: runtimeGraph.subAgentLifecycleHost),
            subAgentCompletion: runtimeGraph.subAgentCompletion,
            runtime: runtime ?? makeRuntimeBackend(
                agentRuntime: runtimeGraph.agentRuntime,
                conversationReplay: runtimeGraph.conversationReplay
            )
        )
    }

    public static func makeConversationAdapter(
        runtimeGraph: HarnessRuntimeGraph
    ) -> APILayerConversationAdapter {
        makeServiceGraph(runtimeGraph: runtimeGraph).conversationAdapter
    }

    static func makeRuntimeService(
        agentRuntime: AgentRuntimeSessionService,
        conversationReplay: ConversationReplayService
    ) -> ChatRuntimeService {
        ChatRuntimeService(
            backend: makeRuntimeBackend(
                agentRuntime: agentRuntime,
                conversationReplay: conversationReplay
            )
        )
    }

    public static func makeGatewayServices(
        runtimeGraph: HarnessRuntimeGraph
    ) -> APILayerChatGatewayServices {
        makeServiceGraph(runtimeGraph: runtimeGraph).gatewayServices
    }

    /// Builds the runtime graph from a wired service bag (composition-root path).
    public static func makeRuntimeGraph(
        services: HarnessRuntimeSessionFactory.Services,
        subAgentLifecycleHost: any SubAgentLifecycleOrchestrationHosting,
        subAgentCompletionHost: any SubAgentCompletionIngressHosting,
        subAgentCompletion: any SubAgentCompletionIngressServicing
    ) -> HarnessRuntimeGraph {
        HarnessRuntimeGraph(
            conversationDomain: services.conversationDomainServices,
            agentRuntime: services.agentRuntimeSessionService,
            conversationReplay: services.conversationReplayService,
            toolPolicyOwner: services.conversationToolModePolicyRuntimeService,
            subAgentLifecycleHost: subAgentLifecycleHost,
            subAgentCompletionHost: subAgentCompletionHost,
            subAgentCompletion: subAgentCompletion
        )
    }

    /// Builds the runtime graph from a runtime session plus composition-root sub-agent services (session is not the gateway owner).
    public static func makeRuntimeGraph(
        host: HarnessRuntimeSession,
        subAgentLifecycleHost: any SubAgentLifecycleOrchestrationHosting,
        subAgentCompletionHost: any SubAgentCompletionIngressHosting,
        subAgentCompletion: any SubAgentCompletionIngressServicing
    ) async -> HarnessRuntimeGraph {
        HarnessRuntimeGraph(
            conversationDomain: await host.conversationDomainServices,
            agentRuntime: await host.agentRuntimeSessionService,
            conversationReplay: await host.conversationReplayService,
            toolPolicyOwner: await host.conversationToolModePolicyRuntimeService,
            subAgentLifecycleHost: subAgentLifecycleHost,
            subAgentCompletionHost: subAgentCompletionHost,
            subAgentCompletion: subAgentCompletion
        )
    }

    public static func makeGatewayServices(
        host: HarnessRuntimeSession,
        subAgentLifecycleHost: any SubAgentLifecycleOrchestrationHosting,
        subAgentCompletionHost: any SubAgentCompletionIngressHosting,
        subAgentCompletion: any SubAgentCompletionIngressServicing
    ) async -> APILayerChatGatewayServices {
        makeGatewayServices(
            runtimeGraph: await makeRuntimeGraph(
                host: host,
                subAgentLifecycleHost: subAgentLifecycleHost,
                subAgentCompletionHost: subAgentCompletionHost,
                subAgentCompletion: subAgentCompletion
            )
        )
    }

    private static func makeRuntimeBackend(
        agentRuntime: AgentRuntimeSessionService,
        conversationReplay: ConversationReplayService
    ) -> RuntimeStreamingOrchestrationService {
        RuntimeStreamingOrchestrationService(
            agentRuntime: agentRuntime,
            conversationReplay: conversationReplay
        )
    }
}
