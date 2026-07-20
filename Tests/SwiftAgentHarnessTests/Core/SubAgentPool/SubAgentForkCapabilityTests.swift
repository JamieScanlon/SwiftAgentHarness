import Foundation
import SwiftAgentKit
import SwiftData
import Testing

@testable import SwiftAgentHarness

@Suite("SubAgent fork capability", .serialized)
struct SubAgentForkCapabilityTests {
    private func makeLocalHost(label: String) async throws -> (
        host: HarnessRuntimeSession,
        root: URL,
        model: Model,
        conversationAPI: APILayerConversationAdapter
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-subagent-fork-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try HarnessTestModelContainer.makeInMemory()
        let model = Model(
            protocol: .openAIAPI,
            modelName: "subagent-fork-\(label)",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let host = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: local)
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: host)
        return (host, root, model, conversationAPI)
    }

    @Test("fork spawn applies requested memory-extraction mode profile")
    func forkSpawnAppliesMemoryExtractionProfile() async throws {
        let fixture = try await makeLocalHost(label: "memory-extraction-mode")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.host.createConversation(
            with: fixture.model,
            userSystemPrompt: "parent-build",
            interactionMode: .agent,
            modeProfileID: "agent"
        )
        let parentID = try #require(await fixture.host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "extract me", timestamp: Date(), toolCalls: [])
        await fixture.host.testing_applyOrchestratorMessages([userMessage])

        let childID = try await fixture.conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .fork,
                userMessageID: userMessage.id,
                taskDescription: "memory-extraction",
                runInBackground: true,
                interactionMode: "memory-extraction"
            ),
            modelOverride: fixture.model
        )

        let child = try #require(await fixture.host.listConversationInfo().first(where: { $0.id == childID }))
        #expect(child.modeProfileID == "memory-extraction")

        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profile = try await registry.resolve(modeId: "memory-extraction")
        let allowedTools = Set(profile.tools.allow ?? [])
        #expect(profile.subAgents.allow == [])
        #expect(!allowedTools.contains(AgentPlanToolProvider.getPlanToolName))
        #expect(allowedTools.contains("read_file"))
        #expect(!allowedTools.contains("spawn_sub_agent"))
        #expect(!allowedTools.contains(ConversationsToolProvider.listConversationsToolName))

        let childConversation = try #require(await fixture.host.modelConversation(id: childID))
        let modeCtx = ModePolicyContext(conversation: childConversation, resolvedProfile: profile)
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let candidateTools = [
            "read_file", "write_file", "get_plan", "spawn_sub_agent",
            ConversationsToolProvider.listConversationsToolName, "schedule_create",
        ]
        let entries = candidateTools.map {
            ToolRegistryEntry(
                definition: ToolDefinition(name: $0, description: "", parameters: [], type: .function),
                source: .local
            )
        }
        let effective = gateway.effectiveToolsForConversation(
            entries: entries,
            conversation: childConversation,
            modePolicyContext: modeCtx,
            configuration: AgentRuntimeTurnConfiguration(
                managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
            ),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        let effectiveNames = Set(effective.map(\.name))
        #expect(effectiveNames.contains("read_file"))
        #expect(effectiveNames.contains("write_file"))
        #expect(!effectiveNames.contains(AgentPlanToolProvider.getPlanToolName))
        #expect(!effectiveNames.contains("spawn_sub_agent"))
        #expect(!effectiveNames.contains(ConversationsToolProvider.listConversationsToolName))
        #expect(!effectiveNames.contains("schedule_create"))
    }

    @Test("fork spawn ignores userSystemPrompt to preserve inherited bytes")
    func forkSpawnIgnoresUserSystemPrompt() async throws {
        let fixture = try await makeLocalHost(label: "fork-system-prompt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.host.createConversation(
            with: fixture.model,
            userSystemPrompt: "parent-build",
            interactionMode: .agent,
            modeProfileID: "agent"
        )
        let parentID = try #require(await fixture.host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "fork me", timestamp: Date(), toolCalls: [])
        await fixture.host.testing_applyOrchestratorMessages([userMessage])
        let parentConversation = try #require(await fixture.host.currentConversation())
        _ = await fixture.host.contextProjectionService.transformedContextMessages(
            from: parentConversation.messages,
            conversation: parentConversation,
            phase: .initial
        )

        let extractionPrompt = "memory extraction system prompt"
        let childID = try await fixture.conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .fork,
                userMessageID: userMessage.id,
                taskDescription: "memory-extraction",
                runInBackground: true,
                userSystemPrompt: extractionPrompt,
                interactionMode: "memory-extraction"
            ),
            modelOverride: fixture.model
        )

        let childConversation = try #require(await fixture.host.modelConversation(id: childID))
        #expect(childConversation.systemPrompt != extractionPrompt)
        #expect(childConversation.systemPrompt == "parent-build")
        let inherited = ConversationMetadataSubagentPromptComposition.inheritedAssembledPromptText(
            from: childConversation.metadata
        )
        #expect(inherited != extractionPrompt)
        #expect(inherited?.contains(extractionPrompt) == false)
    }

    @Test("isolated extraction spawn applies userSystemPrompt and starts clean conversation")
    func isolatedExtractionSpawnAppliesSystemPrompt() async throws {
        let fixture = try await makeLocalHost(label: "isolated-extraction")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.host.createConversation(
            with: fixture.model,
            userSystemPrompt: "parent-build",
            interactionMode: .agent,
            modeProfileID: "agent"
        )
        let parentID = try #require(await fixture.host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "build task", timestamp: Date(), toolCalls: [])
        await fixture.host.testing_applyOrchestratorMessages([userMessage])

        let extractionPrompt = "extract durable memory only"
        let childID = try await fixture.conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .isolated,
                taskDescription: "memory-extraction",
                prompt: "transcript slice",
                runInBackground: true,
                userSystemPrompt: extractionPrompt,
                topic: "memory-extraction",
                interactionMode: "memory-extraction"
            ),
            modelOverride: fixture.model
        )

        let childConversation = try #require(await fixture.host.modelConversation(id: childID))
        #expect(childConversation.modeProfileID == "memory-extraction")
        #expect(childConversation.systemPrompt == extractionPrompt)
        #expect(childConversation.messages.filter { $0.role == .user }.isEmpty)
        #expect(childConversation.parentConversationID == parentID)
    }

    @Test("background fork spawn preserves foreground conversation selection")
    func backgroundForkPreservesForegroundSelection() async throws {
        let fixture = try await makeLocalHost(label: "preserve-selection")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.host.createConversation(
            with: fixture.model,
            userSystemPrompt: "parent-build",
            interactionMode: .agent,
            modeProfileID: "agent"
        )
        let parentID = try #require(await fixture.host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "stay selected", timestamp: Date(), toolCalls: [])
        await fixture.host.testing_applyOrchestratorMessages([userMessage])

        let childID = try await fixture.conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .fork,
                userMessageID: userMessage.id,
                taskDescription: "memory-extraction",
                runInBackground: true,
                interactionMode: "memory-extraction"
            ),
            modelOverride: fixture.model
        )

        #expect(childID != parentID)
        #expect(await fixture.host.currentConversationID == parentID)
    }

    @Test("machine spawn without explicit profile resolves to subagent-minimal")
    func defaultDenyUsesSubagentMinimalProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-subagent-fork-default-deny-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try HarnessTestModelContainer.makeInMemory()
        let model = Model(
            protocol: .openAIAPI,
            modelName: "subagent-fork-default-deny",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let parentNoChildSeed = ResolvedModeProfile(
            id: "parent-no-child-seed",
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: false,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil),
            subAgents: ModeProfileSubAgentsSlice(allow: ["*"], maxDepth: nil, childModeOnSpawnProfileId: nil)
        )
        let modeRegistry = ModeRegistryTestSupport.makePort(
            seedingBuiltIns: true,
            additionalProfiles: [parentNoChildSeed]
        )
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local,
            modeRegistry: modeRegistry
        )
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: host)

        try await host.createConversation(
            with: model,
            userSystemPrompt: "parent-chat",
            interactionMode: .chat,
            modeProfileID: "parent-no-child-seed"
        )
        let parentID = try #require(await host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "fork child", timestamp: Date(), toolCalls: [])
        await host.testing_applyOrchestratorMessages([userMessage])

        let childID = try await conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .fork,
                userMessageID: userMessage.id,
                taskDescription: "unspecified-role",
                runInBackground: true
            ),
            modelOverride: model
        )

        let child = try #require(await host.listConversationInfo().first(where: { $0.id == childID }))
        #expect(child.modeProfileID == "subagent-minimal")
        #expect(child.modeProfileID != InteractionMode.agent.rawValue)
        let minimalProfile = try await modeRegistry.resolve(modeId: "subagent-minimal")
        #expect(minimalProfile.subAgents.allow == [])
        #expect(minimalProfile.tools.allow == [])
    }
}
