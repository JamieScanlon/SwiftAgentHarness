import Foundation

/// Publisher-facing API for session capability registry topics (`tools/registry`, `skills/registry`, `sub-agents/registry`).
public protocol CapabilityRegistryPublishing: Sendable {
    func publishToolsRegistry(_ payload: ToolsRegistryPayload) async
    func publishSkillsRegistry(_ payload: SkillsRegistryPayload) async
    func publishSubAgentsRegistry(_ payload: SubAgentsRegistryPayload) async
}

/// Hub-only wiring when tests inject capability registry wire without a full ``CommunicationLayer``.
public struct CapabilityRegistryHubOnlyPublisher: CapabilityRegistryPublishing {
    private let hub: CapabilityRegistryTopicHub

    public init(hub: CapabilityRegistryTopicHub) {
        self.hub = hub
    }

    public func publishToolsRegistry(_ payload: ToolsRegistryPayload) async {
        guard await hub.hasSubscribers(forTopic: ResourceTopicName.toolsRegistry) else { return }
        await hub.broadcastToolsRegistry(payload)
    }

    public func publishSkillsRegistry(_ payload: SkillsRegistryPayload) async {
        guard await hub.hasSubscribers(forTopic: ResourceTopicName.skillsRegistry) else { return }
        await hub.broadcastSkillsRegistry(payload)
    }

    public func publishSubAgentsRegistry(_ payload: SubAgentsRegistryPayload) async {
        guard await hub.hasSubscribers(forTopic: ResourceTopicName.subAgentsRegistry) else { return }
        await hub.broadcastSubAgentsRegistry(payload)
    }
}
