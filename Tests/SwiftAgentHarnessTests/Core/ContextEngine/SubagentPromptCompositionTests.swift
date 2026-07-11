import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Subagent prompt composition")
struct SubagentPromptCompositionTests {
    private func neutralPolicy() -> ContextEngineSystemPromptAssemblyPolicyInput {
        ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: ResolvedModeProfile(
                id: InteractionMode.agent.rawValue,
                interactionMode: .agent,
                assemblyKind: .agentBuild,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                semanticLayerTags: [],
                context: ModeProfileContextSlice(
                    compactionLevel: "full",
                    modeDirective: "Parent mode directive.",
                    sectionOverrides: [:],
                    suppressSections: [],
                    memoryInjection: "on",
                    includeSkills: true,
                    includeToolGuidance: true
                )
            ),
            strictAgentHarnessPrompts: true,
            includeAgentSkills: false,
            includeDateTime: false,
            toolPolicySignature: "toolsig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
    }

    private func makeAssembleRequest(
        conversation: ModelConversation,
        messages: [Message] = []
    ) -> ContextEngineAssembleRequest {
        ContextEngineAssembleRequest(
            messages: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conversation.id,
                modelID: conversation.model.id.uuidString,
                modelName: conversation.model.modelName,
                interactionMode: conversation.interactionMode,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: nil,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            projectionPolicy: ContextEngineProjectionPolicyInput(systemPromptAssemblyPolicy: neutralPolicy())
        )
    }

    private func baseConversation(
        systemPrompt: String = "parent user prompt",
        metadata: JSON? = nil,
        lineageKind: ConversationLineageKind = .root
    ) -> ModelConversation {
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "composition-test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: systemPrompt
        )
        conversation.metadata = metadata
        conversation.lineageKind = lineageKind
        return conversation
    }

    @Test("fork assemble returns inherited bytes verbatim")
    func forkAssembleReturnsInheritedBytesVerbatim() async throws {
        let inheritedText = "FORK-INHERITED-PROMPT-BYTES"
        let digest = SystemPromptDispatchCodec.sha256Digest(of: inheritedText)
        let parentID = UUID()
        let metadata = ConversationMetadataSubagentPromptComposition.mergingForkInheritance(
            parentConversationID: parentID,
            assembledPromptText: inheritedText,
            assembledPromptDigest: digest,
            replaySpecDigest: "replay-digest",
            into: nil
        )
        let conversation = baseConversation(metadata: metadata, lineageKind: ConversationLineageKind.subAgent)
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            systemPromptAssemblyRenderer: DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil),
            logger: nil
        )
        let result = await engine.assemble(request: makeAssembleRequest(conversation: conversation)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let artifact = try #require(result.projectionArtifact?.systemPromptAssembly)
        #expect(artifact.assembledSystemPromptText == inheritedText)
        #expect(artifact.assembledPromptDigest == digest)
        #expect(artifact.fingerprint == "fork-inherited")
        #expect(artifact.replaySpecDigest == "replay-digest")
    }

    @Test("fork re-assemble on child turn does not re-render")
    func forkReassembleDoesNotRerender() async throws {
        let inheritedText = "STABLE-FORK-BYTES-\(UUID().uuidString)"
        let digest = SystemPromptDispatchCodec.sha256Digest(of: inheritedText)
        let metadata = ConversationMetadataSubagentPromptComposition.mergingForkInheritance(
            parentConversationID: UUID(),
            assembledPromptText: inheritedText,
            assembledPromptDigest: digest,
            replaySpecDigest: nil,
            into: nil
        )
        let conversation = baseConversation(metadata: metadata, lineageKind: ConversationLineageKind.subAgent)
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            systemPromptAssemblyRenderer: DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil),
            logger: nil
        )
        let request = makeAssembleRequest(conversation: conversation)
        let first = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let second = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let firstText = try #require(first.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        let secondText = try #require(second.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        #expect(firstText == inheritedText)
        #expect(secondText == inheritedText)
        #expect(firstText == secondText)
    }

    @Test("spawn suppresses personality memory and identity sections")
    func spawnSuppressesPersonalityMemoryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-suppress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "workspace persona".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let metadata = ConversationMetadataSubagentPromptComposition.mergingSpawnComposition(
            taskDirective: "Delegate task directive.",
            into: nil
        )
        var conversation = baseConversation(metadata: metadata, lineageKind: ConversationLineageKind.subAgent)
        conversation.harnessPersistenceCwd = root.path
        let memoryService = DefaultMemoryService(
            config: .default,
            userConfigDir: root.appendingPathComponent("user", isDirectory: true)
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            systemPromptAssemblyRenderer: renderer,
            logger: nil
        )
        let result = await engine.assemble(request: makeAssembleRequest(conversation: conversation)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let assembled = try #require(result.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        #expect(assembled.contains("Delegate task directive."))
        #expect(assembled.contains("# Personality") == false)
        #expect(assembled.contains("# Memory") == false)
        #expect(assembled.contains("workspace persona") == false)
    }

    @Test("prepareSubagentSpawn spawn composition artifact carries suppressions and directive")
    func prepareSubagentSpawnSpawnCompositionArtifact() async throws {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let request = ContextEnginePrepareSubagentSpawnRequest(
            conversationID: UUID(),
            runID: UUID(),
            candidateToolNames: [],
            permissionPolicyByToolName: [:],
            trustLevelByToolName: [:],
            preApprovedToolNames: [],
            compositionMode: .spawn,
            taskDescription: "summarize logs",
            spawnPrompt: nil,
            spawnUserSystemPrompt: nil
        )
        let result = await engine.prepareSubagentSpawn(request: request)
        let artifact = try #require(result.promptCompositionArtifact)
        #expect(artifact.mode == .spawn)
        #expect(artifact.spawnSectionSuppressions == SystemPromptSubagentComposition.spawnSectionSuppressions)
        #expect(artifact.spawnTaskDirective == "summarize logs")
    }

    @Test("fork child inherits parent assembled prompt digest at spawn anchor")
    func forkChildInheritsParentPromptAtSpawn() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "fork-byte-identity")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        try await fixture.host.createConversation(
            with: model,
            userSystemPrompt: "parent-build-prompt",
            interactionMode: .agent,
            modeProfileID: "agent"
        )
        let parentID = try #require(await fixture.host.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "fork anchor", timestamp: Date(), toolCalls: [])
        await fixture.host.testing_applyOrchestratorMessages([userMessage])
        let parentConversation = try #require(await fixture.host.currentConversation())
        _ = await fixture.host.contextProjectionService.transformedContextMessages(
            from: parentConversation.messages,
            conversation: parentConversation,
            phase: .initial
        )
        let parentAssembly = try #require(
            await fixture.host.contextProjectionService.cachedSystemPromptAssembly(conversationID: parentID)
        )
        let parentText = try #require(parentAssembly.assembledSystemPromptText)
        let parentDigest = try #require(parentAssembly.assembledPromptDigest)

        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: fixture.host)
        let childID = try await conversationAPI.apiSpawnSubAgent(
            parentConversationID: parentID,
            request: SubAgentSpawnRequest(
                context: .fork,
                userMessageID: userMessage.id,
                taskDescription: "memory-extraction",
                runInBackground: true,
                interactionMode: "memory-extraction"
            ),
            modelOverride: model
        )

        let childConversation = try #require(await fixture.host.modelConversation(id: childID))
        #expect(
            ConversationMetadataSubagentPromptComposition.promptCompositionMode(from: childConversation.metadata) == .fork
        )
        #expect(
            ConversationMetadataSubagentPromptComposition.inheritedAssembledPromptText(from: childConversation.metadata)
                == parentText
        )
        #expect(
            ConversationMetadataSubagentPromptComposition.inheritedParentPromptDigest(from: childConversation.metadata)
                == parentDigest
        )

        _ = await fixture.host.contextProjectionService.transformedContextMessages(
            from: childConversation.messages,
            conversation: childConversation,
            phase: .initial
        )
        let childAssembly = try #require(
            await fixture.host.contextProjectionService.cachedSystemPromptAssembly(conversationID: childID)
        )
        #expect(childAssembly.assembledSystemPromptText == parentText)
        #expect(childAssembly.assembledPromptDigest == parentDigest)
    }
}
