import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills
import Testing
@testable import SwiftAgentHarness

@Suite("Cache stability contract")
struct CacheStabilityContractTests {
    private func neutralPolicy(includeDateTime: Bool = false, includeAgentSkills: Bool = false) -> ContextEngineSystemPromptAssemblyPolicyInput {
        ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: ResolvedModeProfile(
                id: InteractionMode.agent.rawValue,
                interactionMode: .agent,
                assemblyKind: .agentBuild,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: true,
                builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                semanticLayerTags: []
            ),
            strictAgentHarnessPrompts: true,
            includeAgentSkills: includeAgentSkills,
            includeDateTime: includeDateTime,
            toolPolicySignature: "toolsig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
    }

    private func makeAssembleRequest(
        messages: [Message],
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput
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
            projectionPolicy: ContextEngineProjectionPolicyInput(systemPromptAssemblyPolicy: policy)
        )
    }

    @Test("ProjectionStabilityContract prefix helper")
    func projectionStabilityContractHelpers() {
        #expect(ProjectionStabilityContract.isBytePrefixExtension(previous: "abc", next: "abcd"))
        #expect(ProjectionStabilityContract.isBytePrefixExtension(previous: "same", next: "same"))
        #expect(ProjectionStabilityContract.isBytePrefixExtension(previous: "abc", next: "abx") == false)
        #expect(ProjectionStabilityContract.firstDivergenceOffset(previous: "abc", next: "abx") == 2)
        #expect(ProjectionStabilityContract.firstDivergenceOffset(previous: "abc", next: "abc") == nil)
    }

    @Test("Consecutive assemble keeps stable system prompt bytes between neutral turns")
    func consecutiveAssembleStableSystemPrompt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "project rule".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

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
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "cache-stability",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "parent prompt"
        )
        conversation.harnessPersistenceCwd = root.path
        let policy = neutralPolicy()
        let baseMessages = [
            Message(id: UUID(), role: .system, content: "parent prompt", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "first", timestamp: Date(), toolCalls: []),
        ]
        let first = await engine.assemble(request: makeAssembleRequest(messages: baseMessages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let firstPrompt = try #require(first.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)

        let secondMessages = baseMessages + [
            Message(id: UUID(), role: .assistant, content: "reply", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "second", timestamp: Date(), toolCalls: []),
        ]
        let second = await engine.assemble(request: makeAssembleRequest(messages: secondMessages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let secondPrompt = try #require(second.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        #expect(firstPrompt == secondPrompt)
    }

    @Test("Projected messages extend prior turn prefix byte-for-byte")
    func projectedMessagesBytePrefixExtension() async throws {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "cache-stability-msgs",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        let policy = neutralPolicy()
        let turnOneMessages = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
        ]
        let turnOne = await engine.assemble(request: makeAssembleRequest(messages: turnOneMessages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let turnTwoMessages = turnOneMessages + [
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
        ]
        let turnTwo = await engine.assemble(request: makeAssembleRequest(messages: turnTwoMessages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let firstSerialized = turnOne.messages.map(\.content).joined(separator: "\n")
        let secondSerialized = turnTwo.messages.map(\.content).joined(separator: "\n")
        #expect(ProjectionStabilityContract.isBytePrefixExtension(previous: firstSerialized, next: secondSerialized))
    }

    @Test("Frozen memory tier1 ignores live snapshot generation bump between assembles")
    func frozenMemoryTier1NeutralAcrossSnapshotBump() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-stability-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "project rule".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

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
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "cache-stability-memory",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        conversation.harnessPersistenceCwd = root.path
        conversation.metadata = ConversationMetadataFrozenMemoryTier1.mergingFrozenMemoryTier1(
            workspaceInstructionSection: "frozen workspace",
            tier1Content: "frozen tier1 index",
            snapshotGeneration: 1,
            into: nil
        )
        let policy = neutralPolicy()
        let messages = [Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])]
        let first = await engine.assemble(request: makeAssembleRequest(messages: messages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let firstPrompt = try #require(first.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)

        let second = await engine.assemble(request: makeAssembleRequest(messages: messages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let secondPrompt = try #require(second.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        #expect(firstPrompt == secondPrompt)
        #expect(firstPrompt.contains("frozen tier1 index"))
        #expect(firstPrompt.contains("project rule") == false)
    }

    @Test("Skill activation does not rewrite assembled system prompt when skills index is frozen")
    func skillActivationDoesNotRewriteStablePrompt() async throws {
        let skillsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-stability-skills-\(UUID().uuidString)", isDirectory: true)
        let skillDir = skillsRoot.appendingPathComponent("demo-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: demo-skill
        description: Demo skill
        ---

        Hidden instructions.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: skillsRoot) }

        let loader = SkillLoader(skillsDirectoryURL: skillsRoot, logger: nil)
        let frozenIndex = SkillPromptFormatter.formatAsXML(try await loader.loadMetadata())
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in loader }, logger: nil)
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            systemPromptAssemblyRenderer: renderer,
            logger: nil
        )
        var conversation = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "cache-stability-skills",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        conversation.metadata = ConversationMetadataFrozenSkillsIndex.mergingFrozenSkillsIndex(
            xml: frozenIndex,
            into: nil
        )
        let policy = neutralPolicy(includeAgentSkills: true)
        let messages = [Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])]
        let before = await engine.assemble(request: makeAssembleRequest(messages: messages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let beforePrompt = try #require(before.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)

        await loader.activateSkill(named: "demo-skill")

        let after = await engine.assemble(request: makeAssembleRequest(messages: messages, conversation: conversation, policy: policy)) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let afterPrompt = try #require(after.projectionArtifact?.systemPromptAssembly?.assembledSystemPromptText)
        #expect(beforePrompt == afterPrompt)
    }
}
