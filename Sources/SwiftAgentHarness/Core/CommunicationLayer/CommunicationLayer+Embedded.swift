import Foundation

extension CommunicationLayer {
    // MARK: - Embedded subscriber registration seams

    public func registerEmbeddedModelPoolSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await modelPoolTopics.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedModelPoolSubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await modelPoolTopics.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedConversationEventsSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await conversationEvents.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedConversationEventsSubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await conversationEvents.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedConversationStateSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await conversationState.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedConversationStateSubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await conversationState.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedTraceSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await traceTopics.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedTraceSubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await traceTopics.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedSubAgentLifecycleSubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await subAgentLifecycle.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedSubAgentLifecycleSubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await subAgentLifecycle.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedCapabilityRegistrySubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await capabilityRegistries.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedCapabilityRegistrySubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await capabilityRegistries.unregisterInProcessSubscriber(token)
    }

    public func registerEmbeddedConversationsRegistrySubscriber(
        _ handler: @escaping @Sendable (String) async -> Void
    ) async -> EmbeddedTopicSubscriberToken {
        await conversationsRegistry.registerInProcessSubscriber(handler)
    }

    public func unregisterEmbeddedConversationsRegistrySubscriber(_ token: EmbeddedTopicSubscriberToken) async {
        await conversationsRegistry.unregisterInProcessSubscriber(token)
    }
}
