import Foundation
import SwiftAgentKit

extension CommunicationLayer {
    /// Publish one `conversation/{id}/state` event when subscribers exist.
    public func broadcastConversationStateIfSubscribed(conversationID: UUID, payload: ConversationStatePayload) async {
        guard await conversationState.hasSubscribers(forConversationID: conversationID) else { return }
        await conversationState.broadcast(conversationID: conversationID, payload: payload)
    }

    public func broadcastConversationTraceIfSubscribed(conversationID: UUID, payload: TraceTopicPayload) async {
        let topic = TraceTopicFormat.conversationTopic(conversationID: conversationID)
        guard await traceTopics.hasSubscribers(forTopic: topic) else { return }
        await traceTopics.broadcastConversation(conversationID: conversationID, payload: payload)
    }

    public func broadcastServerTraceIfSubscribed(payload: TraceTopicPayload) async {
        guard await traceTopics.hasSubscribers(forTopic: TraceTopicFormat.serverTopic) else { return }
        await traceTopics.broadcastServer(payload: payload)
    }

    public func broadcastSubAgentLifecycleEventIfSubscribed(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async {
        let topic = SubAgentTopicFormat.eventsTopic(conversationID: conversationID, pathSegments: pathSegments)
        guard await subAgentLifecycle.hasSubscribers(forTopic: topic) else { return }
        await subAgentLifecycle.broadcastEvent(conversationID: conversationID, pathSegments: pathSegments, payload: payload)
    }

    public func broadcastSubAgentLifecycleStateIfSubscribed(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async {
        let topic = SubAgentTopicFormat.stateTopic(conversationID: conversationID, pathSegments: pathSegments)
        guard await subAgentLifecycle.hasSubscribers(forTopic: topic) else { return }
        await subAgentLifecycle.broadcastState(conversationID: conversationID, pathSegments: pathSegments, payload: payload)
    }

    public func broadcastCapabilityToolsIfSubscribed(_ payload: ToolsRegistryPayload) async {
        guard await capabilityRegistries.hasSubscribers(forTopic: ResourceTopicName.toolsRegistry) else { return }
        await capabilityRegistries.broadcastToolsRegistry(payload)
    }

    public func broadcastCapabilitySkillsIfSubscribed(_ payload: SkillsRegistryPayload) async {
        guard await capabilityRegistries.hasSubscribers(forTopic: ResourceTopicName.skillsRegistry) else { return }
        await capabilityRegistries.broadcastSkillsRegistry(payload)
    }

    public func broadcastCapabilitySubAgentsIfSubscribed(_ payload: SubAgentsRegistryPayload) async {
        guard await capabilityRegistries.hasSubscribers(forTopic: ResourceTopicName.subAgentsRegistry) else { return }
        await capabilityRegistries.broadcastSubAgentsRegistry(payload)
    }

    public func broadcastConversationsRegistryIfSubscribed(_ payload: ConversationsRegistryPayload) async {
        guard await conversationsRegistry.hasSubscribers(forTopic: ResourceTopicName.conversationsRegistry) else { return }
        await conversationsRegistry.broadcastConversationsRegistry(payload)
    }
}

extension CommunicationLayer: CapabilityRegistryPublishing {
    public func publishToolsRegistry(_ payload: ToolsRegistryPayload) async {
        await broadcastCapabilityToolsIfSubscribed(payload)
    }

    public func publishSkillsRegistry(_ payload: SkillsRegistryPayload) async {
        await broadcastCapabilitySkillsIfSubscribed(payload)
    }

    public func publishSubAgentsRegistry(_ payload: SubAgentsRegistryPayload) async {
        await broadcastCapabilitySubAgentsIfSubscribed(payload)
    }
}

extension CommunicationLayer: ConversationsRegistryPublishing {
    public func publishConversationsRegistry(_ payload: ConversationsRegistryPayload) async {
        await broadcastConversationsRegistryIfSubscribed(payload)
    }
}
