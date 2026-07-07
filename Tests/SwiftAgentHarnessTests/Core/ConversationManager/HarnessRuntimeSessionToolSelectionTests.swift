import Foundation
import SwiftData
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSession tool selection", .serialized)
struct HarnessRuntimeSessionToolSelectionTests {

    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "toolsel:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("updateConversationRoutingToolPolicy persists denylist tools across reload")
    func routingPolicyToolsPersist() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        let model = makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationRoutingToolPolicy(
            conversationID: id,
            policy: .denylist(tools: ["alpha", "beta"], skills: [])
        )

        let mem = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        guard case let .denylist(tools, _) = mem.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected denylist routing policy")
            return
        }
        #expect(Set(tools) == Set(["alpha", "beta"]))

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConv = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        guard case let .denylist(reloadedTools, _) = reloadedConv.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected denylist routing policy after reload")
            return
        }
        #expect(Set(reloadedTools) == Set(["alpha", "beta"]))
    }

    @Test("updateConversationRoutingToolPolicy persists denylist skills across reload")
    func routingPolicySkillsPersist() async throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        let model = makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationRoutingToolPolicy(
            conversationID: id,
            policy: .denylist(tools: [], skills: ["skill-a", "skill-b"])
        )

        let mem = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        guard case let .denylist(_, skills) = mem.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected denylist routing policy")
            return
        }
        #expect(Set(skills) == Set(["skill-a", "skill-b"]))

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConv = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        guard case let .denylist(_, reloadedSkills) = reloadedConv.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected denylist routing policy after reload")
            return
        }
        #expect(Set(reloadedSkills) == Set(["skill-a", "skill-b"]))
    }

    @Test("updateConversationThinkingPreference persists thinkingEnabled across reload")
    func thinkingPreferencePersists() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationThinkingPreference(conversationID: id, thinkingEnabled: false)

        let mem = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        #expect(mem.thinkingEnabled == false)

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConv = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(reloadedConv.thinkingEnabled == false)
    }

    @Test("updateConversationReasoningEffort persists reasoningEffort across reload")
    func reasoningEffortPersists() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationReasoningEffort(conversationID: id, reasoningEffort: .low)

        let mem = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        #expect(mem.reasoningEffort == .low)

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConv = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(reloadedConv.reasoningEffort == .low)
    }

    @Test("effectiveAvailableToolEntries returns empty when enableTools is false")
    func effectiveToolEntriesRespectsEnableTools() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()
        let conv = ModelConversation(id: UUID(), model: model, systemPrompt: "s")
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "t1", description: "d", parameters: [], type: .function),
                source: .local
            ),
        ]
        let out = await runtimeSession.orchestratorRuntimeService.effectiveAvailableToolEntries(
            allEntries: entries,
            conversation: conv,
            configuration: .init(enableTools: false, enableAgents: true)
        )
        #expect(out.isEmpty)
    }

    @Test("effectiveAvailableToolEntries removes routing-denied tool names")
    func effectiveToolEntriesRemovesRoutingDeniedTools() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()
        let conv = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "s",
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: ["t2"], skills: [])
            )
        )
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "t1", description: "d", parameters: [], type: .function),
                source: .local
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "t2", description: "d", parameters: [], type: .function),
                source: .local
            ),
        ]
        let out = await runtimeSession.orchestratorRuntimeService.effectiveAvailableToolEntries(
            allEntries: entries,
            conversation: conv,
            configuration: .init(enableTools: true, enableAgents: true)
        )
        #expect(out.map(\.name).sorted() == ["t1"])
    }

    @Test("orchestratorInvocationOptions uses effective tool entries for parallel planner")
    func invocationOptionsUseEffectiveEntriesPlanner() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                parallelDispatchEnabled: true
            )
        )
        let model = makeModel()
        let conv = ModelConversation(id: UUID(), model: model, systemPrompt: "s")

        let readOnlyEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "list_conversations", description: "d", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let unknownEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "remote_dynamic", description: "d", parameters: [], type: .function),
            source: .mcp,
            effectClass: .unknown,
            parallelHint: .unknown
        )

        let pureOptions = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conv,
            effectiveToolEntries: [readOnlyEntry]
        )
        let mixedOptions = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conv,
            effectiveToolEntries: [readOnlyEntry, unknownEntry]
        )
        #expect(pureOptions.parallelToolDispatchEnabled == true)
        #expect(mixedOptions.parallelToolDispatchEnabled == false)
    }

    @Test("orchestratorInvocationOptions maps dispatch planner mode from tool policy")
    func invocationOptionsPlannerModeMapping() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                parallelDispatchEnabled: true,
                dispatchPlannerMode: .mixedDeterministic
            )
        )
        let conv = ModelConversation(id: UUID(), model: makeModel(), systemPrompt: "s")
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.dispatchPlannerMode == .mixedDeterministic)
    }

    @Test("orchestratorInvocationOptions applies built-in chat runtime cap without tools")
    func invocationOptionsApplyBuiltInChatRuntimeCap() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.maxAgenticStepsPerUpdate == nil)
        #expect(options.assistantPersistenceMode == nil)
    }

    @Test("orchestratorInvocationOptions keeps immediate assistant persistence for tool-capable chat turns")
    func invocationOptionsKeepImmediatePersistenceWhenToolsAvailable() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let toolEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "web-search", description: "d", parameters: [], type: .function),
            source: .local
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conv,
            effectiveToolEntries: [toolEntry]
        )
        #expect(options.maxAgenticStepsPerUpdate == nil)
        #expect(options.assistantPersistenceMode == nil)
    }

    @Test("orchestratorInvocationOptions keeps staged assistant persistence in agent mode")
    func invocationOptionsKeepStagedAssistantPersistenceInAgentMode() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.assistantPersistenceMode == nil)
    }

    @Test("orchestratorInvocationOptions applies plan runtime bounds from mode profile")
    func invocationOptionsApplyPlanRuntimeCapFromProfile() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let expectedCap = try await ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
            .resolve(modeId: InteractionMode.plan.rawValue)
            .runtime.maxIterations
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .plan,
            modeProfileID: InteractionMode.plan.rawValue
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.maxAgenticStepsPerUpdate == expectedCap)
    }

    @Test("orchestratorInvocationOptions honors custom non-agent runtime cap")
    func invocationOptionsHonorCustomNonAgentRuntimeCap() async throws {
        let container = try makeContainer()
        let modeRegistryService = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let customID = "plan-runtime-custom-cap"
        try await modeRegistryService.register(
            ResolvedModeProfile(
                id: customID,
                interactionMode: .plan,
                assemblyKind: .planCollaboration,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: 0,
                semanticLayerTags: [],
                runtime: ModeProfileRuntimeSlice(maxIterations: 3, stopOnApprovalRequest: true)
            )
        )
        let runtimeSession = HarnessRuntimeSession(container: container, modeRegistry: ModeRegistryPortAdapter(service: modeRegistryService))
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .plan,
            modeProfileID: customID
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.maxAgenticStepsPerUpdate == 3)
    }

    @Test("forced tool choice remains harness gated and uses maxCorrectionRetries")
    func invocationOptionsForcedToolChoiceHarnessGated() async throws {
        let container = try makeContainer()
        var harness = AgentHarnessConfiguration.default
        harness.maxCorrectionRetries = 7
        let runtimeSession = HarnessRuntimeSession(container: container, agentHarness: harness)

        let chatConv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let agentBuildConv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue
        )

        let chatOptions = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: chatConv,
            forcedToolChoiceRequired: true
        )
        let agentBuildOptions = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: agentBuildConv,
            forcedToolChoiceRequired: true
        )

        #expect(chatOptions.toolInvocationPolicy != .required)
        #expect(agentBuildOptions.toolInvocationPolicy == .required)
        #expect(chatOptions.maxCorrectionRetries != harness.maxCorrectionRetries)
        #expect(agentBuildOptions.maxCorrectionRetries == harness.maxCorrectionRetries)
        #expect(chatOptions.assistantPersistenceMode == nil)
        #expect(agentBuildOptions.assistantPersistenceMode == nil)
    }

    @Test("forced tool choice requires tools when mode profile applies harness")
    func invocationOptionsForcedToolChoiceUsesProfileHarness() async throws {
        let container = try makeContainer()
        let modeRegistryService = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let profileID = "plan-harness-profile"
        try await modeRegistryService.register(
            ResolvedModeProfile(
                id: profileID,
                interactionMode: .plan,
                assemblyKind: .planCollaboration,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: 0,
                semanticLayerTags: [],
                runtime: ModeProfileRuntimeSlice(
                    maxIterations: 8,
                    termination: ModeProfileTerminationSlice(policy: .terminalTool)
                )
            )
        )
        let runtimeSession = HarnessRuntimeSession(container: container, modeRegistry: ModeRegistryPortAdapter(service: modeRegistryService))
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .plan,
            modeProfileID: profileID
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conversation,
            forcedToolChoiceRequired: true
        )
        #expect(options.toolInvocationPolicy == .required)
        #expect(options.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable == true)
    }

    @Test("live pre-dispatch evaluator requires approval from gateway state")
    func livePreDispatchEvaluatorRequiresApproval() async throws {
        let container = try makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(approvalRequiredToolNames: [toolName]),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        await runtimeSession.orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conversation)
        let evaluator = try #require(options.preDispatchPolicyEvaluator)
        let policyContext = ToolPreDispatchPolicyContext(
            request: ToolInvocationRequest(
                toolName: toolName,
                conversationID: conversationID.uuidString,
                source: .model
            ),
            descriptor: nil
        )
        let decision = await evaluator.decide(policyContext)
        #expect(decision.decision == .requireApproval)
        #expect(decision.reasonCode == ToolAvailabilityBlockReason.approvalRequired.rawValue)
        #expect(decision.approvalSpec?.timeoutMs == 120_000)
        #expect(decision.approvalSpec?.timeoutBehavior == ToolPolicyConfiguration.ApprovalTimeoutBehavior.autoDeny.rawValue)
        #expect(decision.approvalSpec?.severity == "medium")
    }

    @Test("live pre-dispatch evaluator allows after approval resolution")
    func livePreDispatchEvaluatorAllowsAfterResolution() async throws {
        let container = try makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(approvalRequiredToolNames: [toolName]),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        await runtimeSession.orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        await runtimeSession.toolApprovalRuntimeService.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: nil,
            toolName: toolName,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        let evaluator = await runtimeSession.orchestratorRuntimeService.livePreDispatchPolicyEvaluator(conversationID: conversationID)
        let decision = await evaluator.decide(
            ToolPreDispatchPolicyContext(
                request: ToolInvocationRequest(
                    toolName: toolName,
                    conversationID: conversationID.uuidString,
                    source: .model
                ),
                descriptor: nil
            )
        )
        #expect(decision.decision == .allow)
    }

    @Test("live pre-dispatch evaluator marks elevated decisions with execution policy reason")
    func livePreDispatchEvaluatorElevatedDecision() async throws {
        let container = try makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(elevatedToolNames: [toolName]),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        await runtimeSession.orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        await runtimeSession.toolApprovalRuntimeService.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: nil,
            toolName: toolName,
            route: .user,
            status: .approved,
            source: "test",
            reason: nil,
            kind: .manual,
            policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
            publicationSource: "test"
        )
        let evaluator = await runtimeSession.orchestratorRuntimeService.livePreDispatchPolicyEvaluator(conversationID: conversationID)
        let decision = await evaluator.decide(
            ToolPreDispatchPolicyContext(
                request: ToolInvocationRequest(
                    toolName: toolName,
                    conversationID: conversationID.uuidString,
                    source: .model
                ),
                descriptor: nil
            )
        )
        #expect(decision.decision == .elevated)
        #expect(decision.reasonCode == "elevated.privilegedDispatch")
    }

    @Test("live pre-dispatch evaluator honors active turn allowEscalatedTools")
    func livePreDispatchEvaluatorHonorsAllowEscalatedTools() async throws {
        let container = try makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let runID = UUID()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(escalationRequiredToolNames: [toolName]),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        await runtimeSession.orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        await runtimeSession.agentRuntimeSessionService.registerActiveTurnConfiguration(
            conversationID: conversationID,
            runID: runID,
            configuration: AgentRuntimeTurnConfiguration(allowEscalatedTools: true)
        )
        let evaluator = await runtimeSession.orchestratorRuntimeService.livePreDispatchPolicyEvaluator(conversationID: conversationID)
        let request = ToolInvocationRequest(
            toolName: toolName,
            conversationID: conversationID.uuidString,
            runID: runID.uuidString,
            source: .model
        )
        let allowed = await evaluator.decide(ToolPreDispatchPolicyContext(request: request, descriptor: nil))
        #expect(allowed.decision == .allow)
    }

    @Test("live pre-dispatch evaluator falls back when active turn configuration is cleared")
    func livePreDispatchEvaluatorFallsBackAfterRegistryClear() async throws {
        let container = try makeContainer()
        let toolName = ConversationsToolProvider.listConversationsToolName
        let runID = UUID()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(escalationRequiredToolNames: [toolName]),
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        await runtimeSession.orchestratorSessionRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        await runtimeSession.agentRuntimeSessionService.registerActiveTurnConfiguration(
            conversationID: conversationID,
            runID: runID,
            configuration: AgentRuntimeTurnConfiguration(allowEscalatedTools: true)
        )
        let evaluator = await runtimeSession.orchestratorRuntimeService.livePreDispatchPolicyEvaluator(conversationID: conversationID)
        let request = ToolInvocationRequest(
            toolName: toolName,
            conversationID: conversationID.uuidString,
            runID: runID.uuidString,
            source: .model
        )
        await runtimeSession.agentRuntimeSessionService.clearActiveTurnConfiguration(runID: runID)
        let denied = await evaluator.decide(ToolPreDispatchPolicyContext(request: request, descriptor: nil))
        #expect(denied.decision == .deny)
        #expect(denied.reasonCode == ToolAvailabilityBlockReason.escalationRequired.rawValue)
    }

    @Test("orchestratorInvocationOptions always binds live pre-dispatch evaluator")
    func invocationOptionsAlwaysAttachPreDispatchEvaluator() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "s", topic: nil, description: nil)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.modelConversation(id: conversationID))
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conversation)
        let evaluator = try #require(options.preDispatchPolicyEvaluator)
        let decision = await evaluator.decide(
            ToolPreDispatchPolicyContext(
                request: ToolInvocationRequest(
                    toolName: "unknown_tool",
                    conversationID: conversationID.uuidString,
                    source: .model
                ),
                descriptor: nil
            )
        )
        #expect(decision.decision == .deny)
        #expect(decision.reasonCode == "tool_not_available")
    }

    @Test("buildToolTurnPolicySnapshot is authoritative for entries and dispatch contract")
    func buildToolTurnPolicySnapshotAuthoritative() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                parallelDispatchEnabled: true
            )
        )
        let conversation = ModelConversation(id: UUID(), model: makeModel(), systemPrompt: "s")
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "read_tool", description: "d", parameters: [], type: .function),
                source: .local,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "unknown_tool", description: "d", parameters: [], type: .mcpTool),
                source: .mcp,
                effectClass: .unknown,
                parallelHint: .unknown
            ),
        ]
        let snapshot = await runtimeSession.orchestratorRuntimeService.buildToolTurnPolicySnapshot(
            allEntries: entries,
            conversation: conversation,
            configuration: .init(enableTools: true, enableAgents: true)
        )
        #expect(snapshot.availabilitySnapshots.count == 2)
        #expect(snapshot.effectiveEntries.map(\.name) == ["read_tool", "unknown_tool"])
        #expect(snapshot.dispatchContract.parallelDispatchEnabled == false)
    }

    @Test("buildToolTurnPolicySnapshot advertises approval-gated tools separately from dispatch contract")
    func buildToolTurnPolicySnapshotAdvertisesApprovalGatedTools() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: ["gated_tool"],
                parallelDispatchEnabled: true
            )
        )
        let conversation = ModelConversation(id: UUID(), model: makeModel(), systemPrompt: "s")
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "gated_tool", description: "d", parameters: [], type: .function),
                source: .local,
                effectClass: .mutating,
                parallelHint: .serialOnly
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "safe_tool", description: "d", parameters: [], type: .function),
                source: .local,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
        ]
        let snapshot = await runtimeSession.orchestratorRuntimeService.buildToolTurnPolicySnapshot(
            allEntries: entries,
            conversation: conversation,
            configuration: .init(enableTools: true, enableAgents: true)
        )
        #expect(snapshot.effectiveEntries.map(\.name) == ["gated_tool", "safe_tool"])
        #expect(snapshot.dispatchContract.parallelDispatchEnabled == true)
    }

    @Test("orchestratorInvocationOptions derives dispatch contract from allowed snapshots")
    func invocationOptionsDeriveDispatchFromSnapshots() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                parallelDispatchEnabled: true
            )
        )
        let conversation = ModelConversation(id: UUID(), model: makeModel(), systemPrompt: "s")
        let safeEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "safe_tool", description: "d", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let blockedEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "blocked_tool", description: "d", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let snapshots: [HarnessRuntimeSession.ToolAvailabilitySnapshot] = [
            .init(
                entry: safeEntry,
                decision: ToolAvailabilityDecision(
                    allowed: true,
                    blockReason: nil,
                    isSensitive: false,
                    requiresEscalation: false,
                    requiresApproval: false,
                    isElevated: false,
                    approvalGranted: false,
                    approvalRoute: nil,
                    delegationPermissionPolicy: nil,
                    delegationTrustLevel: nil
                )
            ),
            .init(
                entry: blockedEntry,
                decision: ToolAvailabilityDecision(
                    allowed: false,
                    blockReason: .promptConfigDenylist,
                    isSensitive: false,
                    requiresEscalation: false,
                    requiresApproval: false,
                    isElevated: false,
                    approvalGranted: false,
                    approvalRoute: nil,
                    delegationPermissionPolicy: nil,
                    delegationTrustLevel: nil
                )
            ),
        ]
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conversation,
            effectiveToolEntries: [blockedEntry],
            availabilitySnapshots: snapshots
        )
        #expect(options.parallelToolDispatchEnabled == true)
    }

    @Test("appendMessagesToConversation does not filter legacy continuation user message id")
    func appendMessagesDoesNotFilterLegacyContinuationMessageID() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await runtimeSession.currentConversationID)

        let legacyContinuationMessage = Message(
            id: UUID(uuidString: "E1F4A2C8-4B0D-4E5F-9A1C-000000000001")!,
            role: .user,
            content: "legacy synthetic continue"
        )
        await runtimeSession.appendMessagesToConversation([legacyContinuationMessage], conversationID: conversationID)

        let messages = try await runtimeSession.listMessages(conversationID: conversationID)
        #expect(messages.contains(where: { $0.id == legacyContinuationMessage.id }))
    }
}
