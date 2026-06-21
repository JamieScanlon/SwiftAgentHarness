import Foundation

/// Harness communication layer aggregate for outbound topic publishing on multiplexed WebSocket topics and in-process fan-out.
/// Inner modules should publish through these hubs—not through ``APILayer`` or raw sockets.
public struct CommunicationLayer: Sendable {
    public let modelPoolTopics: ModelStateTopicHub
    public let conversationEvents: ConversationEventsTopicHub
    public let conversationState: ConversationStateTopicHub
    public let traceTopics: TraceTopicHub
    public let subAgentLifecycle: SubAgentLifecycleTopicHub
    public let capabilityRegistries: CapabilityRegistryTopicHub
    public let conversationsRegistry: ConversationsRegistryTopicHub

    public init(
        modelPoolTopics: ModelStateTopicHub,
        conversationEvents: ConversationEventsTopicHub,
        conversationState: ConversationStateTopicHub,
        traceTopics: TraceTopicHub,
        subAgentLifecycle: SubAgentLifecycleTopicHub,
        capabilityRegistries: CapabilityRegistryTopicHub,
        conversationsRegistry: ConversationsRegistryTopicHub
    ) {
        self.modelPoolTopics = modelPoolTopics
        self.conversationEvents = conversationEvents
        self.conversationState = conversationState
        self.traceTopics = traceTopics
        self.subAgentLifecycle = subAgentLifecycle
        self.capabilityRegistries = capabilityRegistries
        self.conversationsRegistry = conversationsRegistry
    }
}
