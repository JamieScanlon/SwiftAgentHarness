import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Least-privilege PromptConfig mode profiles")
struct LeastPrivilegeModeProfileTests {
    /// Matches `SubAgentSpawnService.defaultMachineSpawnModeProfileID`.
    private static let defaultMachineSpawnProfileID = "subagent-minimal"

    private static let memoryExtractionAllowedTools = [
        "edit_file", "read_attachment", "read_file", "write_file",
    ]

    private static let memoryActiveRecallAllowedTools = [
        MemorySearchToolProvider.searchToolName,
        MemorySearchToolProvider.getToolName,
    ]

    private static let privilegedCandidateTools = [
        "read_file", "read_attachment", "write_file", "edit_file", "glob", "grep", "bash",
        AgentPlanToolProvider.getPlanToolName,
        "spawn_sub_agent",
        ConversationsToolProvider.listConversationsToolName,
        "schedule_create",
        "memory_search",
        "memory_get",
        "memory_write",
    ]

    private func makeConversation(
        modeProfileID: String,
        interactionMode: InteractionMode
    ) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "least-privilege-test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion, .tools],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "sys",
            interactionMode: interactionMode,
            modeProfileID: modeProfileID
        )
    }

    private func effectiveToolNames(
        profile: ResolvedModeProfile,
        conversation: ModelConversation,
        candidates: [String] = privilegedCandidateTools
    ) -> Set<String> {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entries = candidates.map {
            ToolRegistryEntry(
                definition: ToolDefinition(name: $0, description: "", parameters: [], type: .function),
                source: .local
            )
        }
        let modeCtx = ModePolicyContext(conversation: conversation, resolvedProfile: profile)
        let effective = gateway.effectiveToolsForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: AgentRuntimeTurnConfiguration(
                managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
            ),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        return Set(effective.map(\.name))
    }

    @Test("bundled PromptConfig registers least-privilege machine profiles")
    func profilesExistInPromptConfig() async {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let ids = Set(await registry.registeredModeIDs())
        #expect(ids.contains(Self.defaultMachineSpawnProfileID))
        #expect(ids.contains("memory-extraction"))
        #expect(ids.contains("memory-active-recall"))
        #expect(ids.contains("memory-pre-compaction-flush"))
        #expect(ids.contains("trigger-host"))
    }

    @Test("memory-active-recall profile allows memory_search and memory_get only")
    func memoryActiveRecallLockedDownToolset() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: "memory-active-recall")
        #expect(profile.tools.allow?.sorted() == Self.memoryActiveRecallAllowedTools.sorted())
        #expect(profile.subAgents.allow == [])

        let conversation = makeConversation(
            modeProfileID: "memory-active-recall",
            interactionMode: profile.interactionMode
        )
        let effective = effectiveToolNames(profile: profile, conversation: conversation)
        #expect(effective == Set(Self.memoryActiveRecallAllowedTools))
        #expect(!effective.contains("write_file"))
        #expect(!effective.contains("bash"))
        #expect(!effective.contains("memory_write"))
        #expect(!effective.contains("spawn_sub_agent"))
    }

    @Test("subagent-minimal default machine spawn profile denies all tools and sub-agents")
    func subagentMinimalLockedDownToolset() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: Self.defaultMachineSpawnProfileID)
        #expect(profile.tools.allow == [])
        #expect(profile.skills.allow == [])
        #expect(profile.subAgents.allow == [])

        let conversation = makeConversation(
            modeProfileID: Self.defaultMachineSpawnProfileID,
            interactionMode: profile.interactionMode
        )
        #expect(effectiveToolNames(profile: profile, conversation: conversation).isEmpty)
    }

    @Test("memory-extraction profile allows filesystem tools only")
    func memoryExtractionLockedDownToolset() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: "memory-extraction")
        #expect(profile.tools.allow?.sorted() == Self.memoryExtractionAllowedTools.sorted())
        #expect(profile.subAgents.allow == [])
        #expect(profile.context.includeSkills == false)
        #expect(profile.context.includeToolGuidance == false)

        let conversation = makeConversation(
            modeProfileID: "memory-extraction",
            interactionMode: profile.interactionMode
        )
        let effective = effectiveToolNames(profile: profile, conversation: conversation)
        #expect(effective == Set(Self.memoryExtractionAllowedTools))
        #expect(!effective.contains(AgentPlanToolProvider.getPlanToolName))
        #expect(!effective.contains("spawn_sub_agent"))
        #expect(!effective.contains(ConversationsToolProvider.listConversationsToolName))
        #expect(!effective.contains("schedule_create"))
        #expect(!effective.contains("memory_search"))
    }

    @Test("trigger-host profile allows no direct tools and bounded sub-agent delegation")
    func triggerHostLockedDownToolset() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: "trigger-host")
        #expect(profile.tools.allow == [])
        #expect(profile.skills.allow == [])
        #expect(profile.subAgents.allow == ["*"])
        #expect(profile.subAgents.maxDepth == 1)

        let conversation = makeConversation(
            modeProfileID: "trigger-host",
            interactionMode: profile.interactionMode
        )
        #expect(effectiveToolNames(profile: profile, conversation: conversation).isEmpty)
    }
}
