import Foundation

/// Builds conversation-context capability registry payloads for `tools/registry`, `skills/registry`, and `sub-agents/registry`.
enum CapabilityRegistrySnapshotBuilder {
    static func buildTools(conversation: APILayerConversationManaging, conversationID: UUID) async -> ToolsRegistryPayload {
        let now = Date()
        let tools = (try? await conversation.apiListAvailableTools(conversationID: conversationID)) ?? []
        return ToolsRegistryPayload(conversationID: conversationID, tools: tools, updatedAt: now)
    }

    static func buildSkills(conversation: APILayerConversationManaging, conversationID: UUID) async -> SkillsRegistryPayload {
        let now = Date()
        let skills = (try? await conversation.apiListAvailableSkills(conversationID: conversationID)) ?? []
        return SkillsRegistryPayload(conversationID: conversationID, skills: skills, updatedAt: now)
    }

    static func buildSubAgents(conversation: APILayerConversationManaging, conversationID: UUID) async -> SubAgentsRegistryPayload {
        let now = Date()
        let entries = (try? await conversation.apiListSubAgentRegistryEntries(conversationID: conversationID)) ?? []
        let wireEntries = entries.map(\.wirePayload)
        let agents = wireEntries.map(\.tool)
        return SubAgentsRegistryPayload(
            conversationID: conversationID,
            agents: agents,
            entries: wireEntries,
            updatedAt: now
        )
    }
}
