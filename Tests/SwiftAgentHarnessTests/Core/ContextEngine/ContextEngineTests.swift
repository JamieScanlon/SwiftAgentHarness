import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context Engine")
struct ContextEngineTests {
    private func makeAssembleRequest(
        messages: [Message],
        conversation: ModelConversation,
        enableContextTransform: Bool = false,
        persistCompactionCheckpoint: Bool = false,
        projectionPolicy: ContextEngineProjectionPolicyInput? = nil
    ) -> ContextEngineAssembleRequest {
        ContextEngineAssembleRequest(
            messages: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: enableContextTransform,
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
            persistCompactionCheckpoint: persistCompactionCheckpoint,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            projectionPolicy: projectionPolicy
        )
    }

    @Test("DefaultContextEngine passthrough when context transform disabled")
    func enginePassthroughDisabled() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let assembleReq = makeAssembleRequest(
            messages: [],
            conversation: conv,
            persistCompactionCheckpoint: true
        )
        let result = await engine.assemble(request: assembleReq) { _ in
            fatalError("transform must not run")
        }
        #expect(result.messages.isEmpty)
        #expect(result.transformOutput == nil)
        #expect(result.checkpointPersistence == nil)
        #expect(result.transformFailed == false)
        #expect(result.passthroughReason == "context_transform_disabled")
    }

    @Test("DefaultContextEngine assemble keeps tool pair closure across split boundaries")
    func engineAssemblePreservesToolPairClosure() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let model = Model(
            protocol: .openAIAPI,
            modelName: "x",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        let conversation = ModelConversation(model: model, messages: [], systemPrompt: "sys")
        let toolCallID = "tc-engine-split-1"
        let messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: []),
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "web-fetch", arguments: .object([:]), id: toolCallID)]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "payload",
                timestamp: Date(),
                toolCalls: [],
                toolCallId: toolCallID
            ),
            Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a2", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: []),
        ]
        let assembleReq = makeAssembleRequest(
            messages: messages,
            conversation: conversation,
            enableContextTransform: true
        )
        let result = await engine.assemble(request: assembleReq) { input in
            let splitBase = input.compactionSplitBaseMessages ?? input.messages
            let segments = ContextCompactionCheckpointSupport.splitForCompaction(
                splitBase,
                config: assembleReq.compactionConfig,
                modelContextLimitTokens: 200_000
            )
            #expect(segments.middle.contains(where: { $0.role == .tool && $0.toolCallId == toolCallID }))
            return ContextTransformOutput(messages: input.messages, diagnostics: "noop", messageProvenance: nil)
        }
        var outstanding: [String: Int] = [:]
        for message in result.messages {
            if message.role == .assistant {
                for toolCall in message.toolCalls {
                    if let id = toolCall.id, !id.isEmpty {
                        outstanding[id, default: 0] += 1
                    }
                }
            } else if message.role == .tool, let id = message.toolCallId {
                #expect((outstanding[id] ?? 0) > 0)
                outstanding[id, default: 0] -= 1
            }
        }
        #expect(outstanding.values.allSatisfy { $0 == 0 })
    }

    @Test("DefaultContextEngine lifecycle methods provide baseline no-op behavior")
    func engineLifecycleNoopSurface() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conversationID = UUID()
        let runID = UUID()
        let boot = await engine.bootstrap(
            request: ContextEngineBootstrapRequest(
                conversationID: conversationID,
                runID: runID
            )
        )
        #expect(boot.initialized == true)

        let ingestOne = await engine.ingest(
            request: ContextEngineIngestRequest(
                conversationID: conversationID,
                message: Message(id: UUID(), role: .user, content: "u", timestamp: Date(), toolCalls: [])
            )
        )
        #expect(ingestOne.ingestedCount == 1)

        let ingestBatch = await engine.ingestBatch(
            request: ContextEngineIngestBatchRequest(
                conversationID: conversationID,
                messages: [
                    Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: []),
                    Message(id: UUID(), role: .assistant, content: "b", timestamp: Date(), toolCalls: []),
                ]
            )
        )
        #expect(ingestBatch.ingestedCount == 2)

        let prep = await engine.prepareSubagentSpawn(
            request: ContextEnginePrepareSubagentSpawnRequest(
                conversationID: conversationID,
                runID: runID,
                candidateToolNames: ["delegate.alpha", "delegate.beta"],
                permissionPolicyByToolName: [
                    "delegate.alpha": .auto,
                    "delegate.beta": .askUser,
                ],
                trustLevelByToolName: [:],
                preApprovedToolNames: Set(["delegate.beta"])
            )
        )
        #expect(prep.approvedToolNames == ["delegate.alpha", "delegate.beta"])
        #expect(prep.handoffArtifact?.conversationID == conversationID)
        #expect(prep.handoffArtifact?.runID == runID)
        #expect(prep.handoffArtifact?.approvedToolNames == ["delegate.alpha", "delegate.beta"])
        #expect(prep.handoffArtifact?.policyFingerprint.isEmpty == false)
        #expect(prep.checkpointInvalidation?.invalidatedKinds.contains(HarnessCheckpointInvalidationKind.systemPromptAssembly) == true)
        #expect(prep.checkpointInvalidation?.invalidatedKinds.contains(HarnessCheckpointInvalidationKind.attachmentProjection) == true)

        let ended = await engine.onSubagentEnded(
            request: ContextEngineSubagentEndedRequest(
                conversationID: conversationID,
                runID: runID,
                toolName: "delegate.alpha",
                permissionPolicy: .auto,
                trustLevel: .system
            )
        )
        #expect(ended.acknowledged == true)
        #expect(ended.continuationArtifact?.conversationID == conversationID)
        #expect(ended.continuationArtifact?.toolName == "delegate.alpha")
        #expect(ended.continuationArtifact?.policyFingerprint.isEmpty == false)
        #expect(ended.checkpointInvalidation?.invalidatedKinds == [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot])

        let after = await engine.afterTurn(
            request: ContextEngineAfterTurnRequest(
                conversationID: conversationID,
                runID: runID,
                terminalReason: ConversationRunTerminalReason(category: .naturalStop, detail: "done")
            )
        )
        #expect(after.completed == true)
    }

    @Test("DefaultContextEngine injects memory layer snapshot when memory service bootstraps")
    func engineLifecycleAssemblyInjectsDeterministicMemory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let baseMessages = [Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: [])]
        let policy = ContextEngineProjectionPolicyInput(
            systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
                resolvedModeProfile: ResolvedModeProfile(
                    id: InteractionMode.chat.rawValue,
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                    semanticLayerTags: []
                ),
                strictAgentHarnessPrompts: true,
                includeAgentSkills: false,
                includeDateTime: false,
                toolPolicySignature: "toolsig",
                routingPolicyTools: [],
                routingPolicySkills: []
            )
        )
        let request = makeAssembleRequest(
            messages: baseMessages,
            conversation: conv,
            enableContextTransform: true,
            projectionPolicy: policy
        )
        let t1 = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let t2 = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let s1 = t1.memoryInjectionSnapshot
        let s2 = t2.memoryInjectionSnapshot
        #expect(s1 == nil)
        #expect(s2 == nil)
        let artifact = try #require(t1.projectionArtifact?.systemPromptAssembly)
        #expect(artifact.tier1MemorySectionContent?.contains("project rule") == false)
        #expect(artifact.memorySnapshotGeneration != nil)
        #expect(!t1.messages.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.memoryContext) }))
        let assembled = try #require(artifact.assembledSystemPromptText)
        #expect(assembled.contains("project rule"))
        #expect(assembled.contains("# Personality"))
        #expect(assembled.contains("# Memory"))
        #expect(assembled.contains("<!-- provenance: engine:memory -->") == false || assembled.contains("<memory-context>"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("DefaultContextEngine applies Tier 2 recall late with byte budgets")
    func engineTier2RecallLateInjectionWithBudgets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-tier2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = DefaultMemoryService(
            config: .default,
            userConfigDir: root.appendingPathComponent("user", isDirectory: true)
        )
        let engine = DefaultContextEngine(compactionCoordinator: nil, memoryService: service, logger: nil)
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 200_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let context = try service.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await service.bootstrapSession(context: context)
        let largeBody = String(repeating: "x", count: 10_000)
        try """
        ---
        name: Big Topic
        description: oversized recall body
        type: project
        ---
        \(largeBody)
        """.write(
            to: context.memoryDirectory.appendingPathComponent("big-topic.md"),
            atomically: true,
            encoding: .utf8
        )

        let userID = UUID()
        let baseMessages: [Message] = [
            Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .user, content: "prior turn", timestamp: Date(), toolCalls: []),
            Message(id: userID, role: .user, content: "big topic oversized recall", timestamp: Date(), toolCalls: []),
        ]
        let request = ContextEngineAssembleRequest(
            messages: baseMessages,
            conversation: conv,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 200_000,
            lastPromptTokens: 100,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let recallMessages = result.messages.filter {
            $0.content.contains(HarnessInjectedMessagePrefixes.memoryRecall)
        }
        #expect(recallMessages.count == 1)
        let recallIndex = try #require(result.messages.firstIndex(where: { $0.id == recallMessages[0].id }))
        let lastUserIndex = try #require(result.messages.lastIndex(where: { $0.role == .user }))
        #expect(recallIndex + 1 == lastUserIndex)
        #expect(result.messages[lastUserIndex].content == "big topic oversized recall")
        let recallBody = recallMessages[0].content
        #expect(recallBody.contains(MemoryRecallInjectionPolicy.truncationMarker))
        #expect(result.passthroughReason != "context_compacted")
        #expect(result.memoryInjectionSnapshot?.injectedMemoryEntryIDs.count == 1)
        #expect(result.projectedMemorySelectionKeys.contains("big-topic.md"))
    }

    @Test("DefaultContextEngine skips Tier 2 recall when tier1 already body-projects same selectionKey")
    func engineTier2SkipsWhenTier1AlreadyProjectsBody() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-cross-tier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = "dup fact from tier1"
        let tier1Embedded = MemoryRecallBodyFormatter.format(scope: .project, filename: "dup-topic.md", body: body)
        try tier1Embedded.write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let service = DefaultMemoryService(
            config: .default,
            userConfigDir: root.appendingPathComponent("user", isDirectory: true)
        )
        let engine = DefaultContextEngine(compactionCoordinator: nil, memoryService: service, logger: nil)
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 200_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let context = try service.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await service.bootstrapSession(context: context)
        try """
        ---
        name: Dup Topic
        description: cross-tier dedupe target
        type: project
        ---
        \(body)
        """.write(
            to: context.memoryDirectory.appendingPathComponent("dup-topic.md"),
            atomically: true,
            encoding: .utf8
        )

        let userID = UUID()
        let policy = ContextEngineProjectionPolicyInput(
            systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
                resolvedModeProfile: ResolvedModeProfile(
                    id: InteractionMode.chat.rawValue,
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                    semanticLayerTags: []
                ),
                strictAgentHarnessPrompts: true,
                includeAgentSkills: false,
                includeDateTime: false,
                toolPolicySignature: "toolsig",
                routingPolicyTools: [],
                routingPolicySkills: []
            )
        )
        let request = ContextEngineAssembleRequest(
            messages: [
                Message(id: UUID(), role: .system, content: "system", timestamp: Date(), toolCalls: []),
                Message(id: userID, role: .user, content: "dup topic cross tier dedupe", timestamp: Date(), toolCalls: []),
            ],
            conversation: conv,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 200_000,
            lastPromptTokens: 100,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            projectionPolicy: policy
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let recallMessages = result.messages.filter {
            $0.content.contains(HarnessInjectedMessagePrefixes.memoryRecall)
        }
        #expect(recallMessages.isEmpty)
        #expect(result.projectedMemorySelectionKeys.isEmpty)
        #expect(result.memoryInjectionSnapshot == nil)
    }

    @Test("ContextEngineSlotResolver resolves noop slot and unknown falls back")
    func contextEngineSlotResolverSemantics() async {
        let coordinator = CompactionConcurrencyCoordinator()
        let noop = ContextEngineSlotResolver.resolve(
            slotID: "noop",
            compactionCoordinator: coordinator,
            logger: nil
        )
        #expect(noop != nil)
        let unknown = ContextEngineSlotResolver.resolve(
            slotID: "not_a_slot",
            compactionCoordinator: coordinator,
            logger: nil
        )
        #expect(unknown == nil)
    }

    @Test("DefaultContextEngine applies trust downgrade in projection policy stage")
    func engineProjectionPolicyAppliesTrustDowngrade() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let oldLowTrust = Message(
            id: UUID(),
            role: .user,
            content: "old low trust",
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: MessageInputTrust.scripted.rawValue
        )
        let assistant = Message(id: UUID(), role: .assistant, content: "ack", timestamp: Date(), toolCalls: [])
        let latestLowTrust = Message(
            id: UUID(),
            role: .user,
            content: "latest low trust",
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: MessageInputTrust.automation.rawValue
        )
        let assembleReq = makeAssembleRequest(
            messages: [oldLowTrust, assistant, latestLowTrust],
            conversation: conv,
            projectionPolicy: ContextEngineProjectionPolicyInput(
                requestInputTrustRaw: MessageInputTrust.scripted.rawValue,
                safeDefaultTrustClass: .lowTrust,
                downgradeLowTrustContext: true
            )
        )
        let result = await engine.assemble(request: assembleReq) { _ in
            fatalError("transform must not run")
        }
        #expect(result.messages.contains(where: { $0.id == assistant.id }))
        #expect(result.messages.contains(where: { $0.id == latestLowTrust.id }))
        #expect(!result.messages.contains(where: { $0.id == oldLowTrust.id }))
        #expect(result.projectionArtifact?.resolvedRequestTrustClass == .lowTrust)
    }

    @Test("DefaultContextEngine emits system prompt checkpoint projection artifact")
    func engineProjectionEmitsSystemPromptCheckpoint() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s",
            interactionMode: .agent
        )
        let policy = ContextEngineProjectionPolicyInput(
            systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
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
                includeAgentSkills: true,
                includeDateTime: true,
                toolPolicySignature: "toolsig",
                routingPolicyTools: [],
                routingPolicySkills: []
            )
        )
        let assembleReq = makeAssembleRequest(
            messages: [Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])],
            conversation: conv,
            projectionPolicy: policy
        )
        let result = await engine.assemble(request: assembleReq) { _ in
            fatalError("transform must not run")
        }
        #expect(result.systemPromptCheckpoint?.conversationID == conv.id)
        #expect(result.systemPromptCheckpoint?.fingerprint.isEmpty == false)
        let metadata = result.projectionArtifact?.systemPromptAssembly?.metadata ?? [:]
        #expect(metadata["conversationID"] == nil)
        #expect(metadata["modeDirective"] == nil)
    }

    @Test("DefaultContextEngine applies mode context switches through typed assembly")
    func engineProjectionAppliesModeContextSwitches() async {
        final class CapturingRenderer: SystemPromptAssemblyRendering, @unchecked Sendable {
            private let lock = NSLock()
            private var _contributions: [SystemPromptContribution] = []
            private var _context: SystemPromptAssemblyContext?

            var contributions: [SystemPromptContribution] {
                lock.withLock { _contributions }
            }

            var context: SystemPromptAssemblyContext? {
                lock.withLock { _context }
            }

            func render(
                conversation: ModelConversation,
                policy: ContextEngineSystemPromptAssemblyPolicyInput,
                userSystemPrompt: String?,
                assemblyContext: SystemPromptAssemblyContext,
                contributions: [SystemPromptContribution],
                referenceDate: Date,
                fullOverrideText: String?
            ) async throws -> String {
                lock.withLock {
                    _contributions = contributions
                    _context = assemblyContext
                }
                return "MODE_SWITCH_PROBE"
            }

            func renderWithAudit(
                conversation: ModelConversation,
                policy: ContextEngineSystemPromptAssemblyPolicyInput,
                userSystemPrompt: String?,
                assemblyContext: SystemPromptAssemblyContext,
                contributions: [SystemPromptContribution],
                referenceDate: Date,
                fullOverrideText: String?
            ) async throws -> SystemPromptAssemblyRenderAudit {
                let text = try await render(
                    conversation: conversation,
                    policy: policy,
                    userSystemPrompt: userSystemPrompt,
                    assemblyContext: assemblyContext,
                    contributions: contributions,
                    referenceDate: referenceDate,
                    fullOverrideText: fullOverrideText
                )
                return SystemPromptAssemblyRenderAudit(
                    text: text,
                    product: SystemPromptAssemblyRenderProduct(
                        text: text,
                        sectionProvenance: [:],
                        skillSnapshot: SystemPromptSkillRenderSnapshot(
                            activatedSkillNames: [],
                            skillsIndexDigest: nil
                        ),
                        frozenSkillsIndexXML: nil
                    ),
                    effectiveUserSystemPrompt: userSystemPrompt ?? "",
                    providerStablePrefix: nil
                )
            }
        }
        let renderer = CapturingRenderer()
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            systemPromptAssemblyRenderer: renderer,
            logger: nil
        )
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let resolved = ResolvedModeProfile(
            id: "context.switch.profile",
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: false,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            context: ModeProfileContextSlice(
                compactionLevel: "full",
                modeDirective: "Focus on code review only.",
                sectionOverrides: [
                    "tools": "Only cite tools when explicitly requested.",
                ],
                suppressSections: ["skills"],
                memoryInjection: "off",
                includeSkills: false,
                includeToolGuidance: false
            )
        )
        let policy = ContextEngineProjectionPolicyInput(
            systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
                resolvedModeProfile: resolved,
                strictAgentHarnessPrompts: true,
                includeAgentSkills: false,
                includeDateTime: true,
                toolPolicySignature: "toolsig",
                routingPolicyTools: [],
                routingPolicySkills: []
            )
        )
        let assembleReq = makeAssembleRequest(
            messages: [Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])],
            conversation: conv,
            projectionPolicy: policy
        )
        let result = await engine.assemble(request: assembleReq) { _ in
            fatalError("transform must not run")
        }
        let modeContribution = renderer.contributions.first(where: { $0.source == .mode })
        #expect(modeContribution?.sectionDirectives[.modeDirective] == "Focus on code review only.")
        #expect(modeContribution?.suppress.contains(.skills) == true)
        #expect(modeContribution?.sectionOverrides[.toolGuidance] == "Only cite tools when explicitly requested.")
        #expect(renderer.context?.memoryInjectionMode == "off")
        #expect(renderer.context?.includeAgentSkills == false)
        #expect(renderer.context?.includeToolGuidance == false)
        #expect(renderer.context?.modeCompactionLevel == "full")
        #expect(result.projectionArtifact?.systemPromptAssembly?.metadata["modeDirective"] == nil)
    }

    @Test("DefaultContextEngine embeds assembled system prompt when renderer is wired")
    func engineEmbedsAssembledSystemPromptWithDigest() async throws {
        struct StubRenderer: SystemPromptAssemblyRendering {
            func render(
                conversation: ModelConversation,
                policy: ContextEngineSystemPromptAssemblyPolicyInput,
                userSystemPrompt: String?,
                assemblyContext: SystemPromptAssemblyContext,
                contributions: [SystemPromptContribution],
                referenceDate: Date,
                fullOverrideText: String?
            ) async throws -> String {
                let tier1 = assemblyContext.tier1MemoryContent ?? ""
                let iso = ISO8601DateFormatter().string(from: referenceDate)
                return "ASSEMBLED:\(userSystemPrompt ?? ""):\(tier1):\(iso)"
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-sp1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "tier-one rule".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let memoryService = DefaultMemoryService(
            config: .default,
            userConfigDir: root.appendingPathComponent("user", isDirectory: true)
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            systemPromptAssemblyRenderer: StubRenderer(),
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "seed prompt"
        )
        conv.harnessPersistenceCwd = root.path
        let policy = ContextEngineProjectionPolicyInput(
            systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
                resolvedModeProfile: ResolvedModeProfile(
                    id: InteractionMode.chat.rawValue,
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                    semanticLayerTags: []
                ),
                strictAgentHarnessPrompts: true,
                includeAgentSkills: false,
                includeDateTime: false,
                toolPolicySignature: "toolsig",
                routingPolicyTools: [],
                routingPolicySkills: []
            )
        )
        let request = makeAssembleRequest(
            messages: [Message(id: UUID(), role: .system, content: "seed prompt", timestamp: Date(), toolCalls: [])],
            conversation: conv,
            enableContextTransform: false,
            projectionPolicy: policy
        )
        let first = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let second = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let artifact = try #require(first.projectionArtifact?.systemPromptAssembly)
        let canonical = try #require(
            first.messages.first(where: { $0.role == .system && !HarnessInjectedMessageMetadata.isHarnessInjected($0) })
        )
        #expect(canonical.content.hasPrefix("ASSEMBLED:seed prompt:"))
        #expect(canonical.content.contains("tier-one rule") == false)
        #expect(artifact.assembledPromptDigest == SystemPromptDispatchCodec.sha256Digest(of: canonical.content))
        #expect(first.systemPromptCheckpoint?.assembledPromptDigest == artifact.assembledPromptDigest)
        #expect(
            second.messages.first(where: { $0.role == .system && !HarnessInjectedMessageMetadata.isHarnessInjected($0) })?
                .content == canonical.content
        )
        let metadata = artifact.metadata
        #expect(metadata[SystemPromptAssemblyMetadataKeys.assembledPromptDigest] == artifact.assembledPromptDigest)
        #expect(metadata[SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO] != nil)
        #expect(metadata[SystemPromptAssemblyMetadataKeys.replaySpecDigest] == artifact.replaySpecDigest)
        #expect(metadata[SystemPromptAssemblyMetadataKeys.tier1MemoryContent] == nil)
    }

    @Test("System prompt checkpoint fingerprint changes with context override value changes")
    func systemPromptFingerprintTracksContextOverrideValues() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let profileA = ResolvedModeProfile(
            id: "fingerprint.profile",
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: false,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            context: ModeProfileContextSlice(sectionOverrides: ["tools": "A"])
        )
        let profileB = ResolvedModeProfile(
            id: "fingerprint.profile",
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: false,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            context: ModeProfileContextSlice(sectionOverrides: ["tools": "B"])
        )
        let makeRequest: (ResolvedModeProfile) -> ContextEngineAssembleRequest = { profile in
            makeAssembleRequest(
                messages: [Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])],
                conversation: conv,
                projectionPolicy: ContextEngineProjectionPolicyInput(
                    systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput(
                        resolvedModeProfile: profile,
                        strictAgentHarnessPrompts: true,
                        includeAgentSkills: true,
                        includeDateTime: true,
                        toolPolicySignature: "toolsig",
                        routingPolicyTools: [],
                        routingPolicySkills: []
                    )
                )
            )
        }
        let resultA = await engine.assemble(request: makeRequest(profileA)) { _ in
            fatalError("transform must not run")
        }
        let resultB = await engine.assemble(request: makeRequest(profileB)) { _ in
            fatalError("transform must not run")
        }
        #expect(resultA.systemPromptCheckpoint?.fingerprint != resultB.systemPromptCheckpoint?.fingerprint)
    }

    @Test("DefaultContextEngine emits attachment projection decisions and checkpoint")
    func engineProjectionEmitsAttachmentProjectionCheckpoint() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let trusted = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "image",
            name: "diagram.png",
            mimeType: "image/png",
            byteSize: 10_000,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let lowTrust = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "document",
            name: "generated.pdf",
            mimeType: "application/pdf",
            byteSize: 4_000_000,
            trustRaw: AttachmentInputTrust.automation.rawValue
        )
        let policy = ContextEngineProjectionPolicyInput(
            attachmentCatalog: [trusted, lowTrust],
            modelSupportsVision: false,
            attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput(
                enabled: true,
                inlineByteLimit: 20_000,
                summarizeByteLimit: 1_000_000
            )
        )
        let assembleReq = makeAssembleRequest(
            messages: [Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])],
            conversation: conv,
            projectionPolicy: policy
        )
        let result = await engine.assemble(request: assembleReq) { _ in
            fatalError("transform must not run")
        }
        let checkpoint = try? #require(result.attachmentProjectionCheckpoint)
        #expect(checkpoint?.conversationID == conv.id)
        #expect(checkpoint?.decisions.count == 2)
        let trustedDecision = checkpoint?.decisions.first(where: { $0.attachmentName == "diagram.png" })
        let lowTrustDecision = checkpoint?.decisions.first(where: { $0.attachmentName == "generated.pdf" })
        #expect(trustedDecision?.disposition == .summarize)
        #expect(lowTrustDecision?.disposition == .searchOnly)
    }

    @Test("DefaultContextEngine emits pre-compaction memory flush spec after successful flush")
    func engineEmitsPreCompactionMemoryFlushSpec() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let flushedID = UUID()
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [flushedID]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)
        let longBody = String(repeating: "token ", count: 8000)
        var messages: [Message] = []
        for index in 0..<12 {
            messages.append(Message(id: UUID(), role: .user, content: "\(longBody) user \(index)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "\(longBody) assistant \(index)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest user", timestamp: Date(), toolCalls: []))
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16
            )
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(result.preCompactionMemoryFlush?.conversationID == conv.id)
        #expect(result.preCompactionMemoryFlush?.flushedMemoryEntryIDs == [flushedID])
        #expect(await stubRunner.lastContext?.middleMessages.isEmpty == false)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("DefaultContextEngine collects provider pre-compress notes after flush and before transform")
    func engineCollectsProviderPreCompressNotesBeforeTransform() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-precompress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)
        await memoryService.registerActiveMemoryCapability(
            MemoryCapability(
                pluginID: "test-precompress",
                runtime: StubPreCompressMemoryRuntime(note: "Durable fact from external provider.")
            )
        )
        let longBody = String(repeating: "token ", count: 8000)
        var messages: [Message] = []
        for index in 0..<12 {
            messages.append(Message(id: UUID(), role: .user, content: "\(longBody) user \(index)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "\(longBody) assistant \(index)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest user", timestamp: Date(), toolCalls: []))
        let noteCapture = ProviderPreCompressNoteCapture()
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16
            )
        )
        _ = await engine.assemble(request: request) { input in
            await noteCapture.set(input.compactionProviderPreCompressNotes)
            return ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(await noteCapture.value == "Durable fact from external provider.")
        try? FileManager.default.removeItem(at: root)
    }

    @Test("DefaultContextEngine skips pre-compaction flush when persistCompactionCheckpoint is false")
    func engineSkipsPreCompactionFlushWhenPersistenceDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-flush-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)
        let longBody = String(repeating: "token ", count: 8000)
        var messages: [Message] = []
        for index in 0..<12 {
            messages.append(Message(id: UUID(), role: .user, content: "\(longBody) user \(index)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "\(longBody) assistant \(index)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest user", timestamp: Date(), toolCalls: []))
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16
            )
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(result.preCompactionMemoryFlush == nil)
        #expect(await stubRunner.lastContext == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Soft threshold flush-only: flush runs, transform does not")
    func softThresholdFlushOnlyDoesNotTransform() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-soft-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let flushedID = UUID()
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [flushedID]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        // hard = 80_000, soft = 72_000; prompt in soft band
        let lastPromptTokens = 75_000

        let messages = Self.longTranscriptForFlushTests()
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: .production,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: lastPromptTokens,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 8_000
            )
        )
        let transformCounter = TransformCallCounter()
        let result = await engine.assemble(request: request) { input in
            await transformCounter.increment()
            return ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(await transformCounter.count == 0)
        #expect(result.transformOutput == nil)
        #expect(result.passthroughReason == "context_compaction_noop_under_token_threshold")
        #expect(result.preCompactionMemoryFlush?.flushedMemoryEntryIDs == [flushedID])
        #expect(await stubRunner.callCount == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Hard threshold still flushes then transforms")
    func hardThresholdFlushThenTransform() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-hard-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let flushedID = UUID()
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [flushedID]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        config.middleMinCharactersForCompactionLLM = 0
        config.compactionLLMCooldownSeconds = 0
        let lastPromptTokens = 85_000

        let messages = Self.longTranscriptForFlushTests()
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: .production,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: lastPromptTokens,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 8_000
            )
        )
        let transformCounter = TransformCallCounter()
        let result = await engine.assemble(request: request) { input in
            await transformCounter.increment()
            return ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(await transformCounter.count == 1)
        #expect(result.transformOutput != nil)
        #expect(result.preCompactionMemoryFlush?.flushedMemoryEntryIDs == [flushedID])
        #expect(await stubRunner.callCount == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Under soft threshold: neither flush nor transform")
    func underSoftThresholdNeitherFlushNorTransform() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-under-soft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        let lastPromptTokens = 50_000

        let messages = Self.longTranscriptForFlushTests()
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: .production,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: lastPromptTokens,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 8_000
            )
        )
        let transformCounter = TransformCallCounter()
        let result = await engine.assemble(request: request) { input in
            await transformCounter.increment()
            return ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(await transformCounter.count == 0)
        #expect(result.preCompactionMemoryFlush == nil)
        #expect(await stubRunner.callCount == 0)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Soft flush dedupe: second soft assemble does not re-flush")
    func softFlushDedupeSkipsSecondSoftAssemble() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-soft-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        let messages = Self.longTranscriptForFlushTests()

        func makeRequest() -> ContextEngineAssembleRequest {
            ContextEngineAssembleRequest(
                messages: messages,
                conversation: conv,
                phase: .initial,
                gatingOverride: .production,
                compactionCustomInstructionsOverride: nil,
                enableContextTransform: true,
                compactionConfig: config,
                transformMetadata: ConversationTransformMetadata(
                    conversationID: conv.id,
                    modelID: conv.model.id.uuidString,
                    modelName: conv.model.modelName,
                    interactionMode: .chat,
                    routingPolicyTools: [],
                    routingPolicySkills: [],
                    thinkingEnabled: false,
                    reasoningEffort: nil,
                    metadata: nil
                ),
                lastContextLimitTokens: 100_000,
                lastPromptTokens: 75_000,
                events: [],
                eventLogFrontier: 0,
                lastLLMDateByConversationID: [:],
                persistCompactionCheckpoint: true,
                allowProactiveCompactionTriggers: true,
                compactionLockAlreadyHeldByCaller: false,
                derivedTailAtProjectionStart: 0,
                preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                    enabled: true,
                    maxFlushedMemoryEntries: 16,
                    softThresholdTokens: 8_000
                )
            )
        }

        let first = await engine.assemble(request: makeRequest()) { input in
            fatalError("transform must not run on soft path")
        }
        #expect(first.preCompactionMemoryFlush != nil)
        #expect(await stubRunner.callCount == 1)

        let second = await engine.assemble(request: makeRequest()) { input in
            fatalError("transform must not run on soft path")
        }
        #expect(second.preCompactionMemoryFlush == nil)
        #expect(await stubRunner.callCount == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Soft flush then hard compaction skips duplicate flush on same middle coverage")
    func softThenHardSkipsDuplicateFlush() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-soft-hard-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        let messages = Self.longTranscriptForFlushTests()

        let softRequest = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: .production,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: 75_000,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 8_000
            )
        )
        _ = await engine.assemble(request: softRequest) { _ in
            fatalError("transform must not run on soft path")
        }
        #expect(await stubRunner.callCount == 1)

        let hardRequest = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: 85_000,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 8_000
            )
        )
        _ = await engine.assemble(request: hardRequest) { input in
            ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionCheckpointKind.summarizedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(await stubRunner.callCount == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Hard compaction checkpoint clears flush dedupe cycle for subsequent flush")
    func hardCheckpointClearsFlushDedupeCycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-flush-cycle-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)
        let messages = Self.longTranscriptForFlushTests()
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.compactionMinPromptTokenSavingsFraction = 0
        compactionConfig.middleMinCharactersForCompactionLLM = 0

        func hardRequest() -> ContextEngineAssembleRequest {
            ContextEngineAssembleRequest(
                messages: messages,
                conversation: conv,
                phase: .initial,
                gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
                compactionCustomInstructionsOverride: nil,
                enableContextTransform: true,
                compactionConfig: compactionConfig,
                transformMetadata: ConversationTransformMetadata(
                    conversationID: conv.id,
                    modelID: conv.model.id.uuidString,
                    modelName: conv.model.modelName,
                    interactionMode: .chat,
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
                persistCompactionCheckpoint: true,
                allowProactiveCompactionTriggers: true,
                compactionLockAlreadyHeldByCaller: false,
                derivedTailAtProjectionStart: 0,
                preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                    enabled: true,
                    maxFlushedMemoryEntries: 16
                )
            )
        }

        let first = await engine.assemble(request: hardRequest()) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        _ = first
        #expect(await stubRunner.callCount == 1)

        await memoryService.clearPreCompactionFlushCycle(conversationID: conv.id)

        _ = await engine.assemble(request: hardRequest()) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(await stubRunner.callCount == 2)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Overlapping compaction middle flushes only novel message IDs")
    func overlappingMiddleFlushesNovelMessagesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-flush-novel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        let base = Self.longTranscriptForFlushTests()
        let novel = Message(id: UUID(), role: .user, content: "brand new middle fact", timestamp: Date(), toolCalls: [])
        var expanded = base
        expanded.insert(novel, at: 10)

        let firstRequest = ContextEngineAssembleRequest(
            messages: base,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16
            )
        )
        _ = await engine.assemble(request: firstRequest) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        let firstMiddleIDs = Set(await stubRunner.lastContext?.middleMessages.map(\.id) ?? [])
        #expect(!firstMiddleIDs.isEmpty)

        let secondRequest = ContextEngineAssembleRequest(
            messages: expanded,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16
            )
        )
        _ = await engine.assemble(request: secondRequest) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(await stubRunner.callCount == 2)
        let secondMiddleIDs = Set(await stubRunner.lastContext?.middleMessages.map(\.id) ?? [])
        #expect(secondMiddleIDs.contains(novel.id))
        #expect(firstMiddleIDs.isDisjoint(with: secondMiddleIDs))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("softThresholdTokens 0 disables soft flush; flush only on hard path")
    func softThresholdZeroDisablesSoftFlush() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-soft-zero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryService = DefaultMemoryService(userConfigDir: root.appendingPathComponent("user", isDirectory: true))
        let stubRunner = StubPreCompactionFlushRunner(
            result: PreCompactionMemoryFlushResult(
                succeeded: true,
                memoryStoreVersion: 1,
                flushedMemoryEntryIDs: [UUID()]
            )
        )
        let engine = DefaultContextEngine(
            compactionCoordinator: nil,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: stubRunner,
            logger: nil
        )
        var conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI,
                maxContextLength: 100_000
            ),
            messages: [],
            systemPrompt: "s"
        )
        conv.harnessPersistenceCwd = root.path
        let ctx = try memoryService.makeSessionContext(conversationID: conv.id, cwd: root.path)
        _ = try await memoryService.bootstrapSession(context: ctx)

        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 0

        let messages = Self.longTranscriptForFlushTests()
        let softBandRequest = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: .production,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: config,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 100_000,
            lastPromptTokens: 75_000,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: true,
                maxFlushedMemoryEntries: 16,
                softThresholdTokens: 0
            )
        )
        let softResult = await engine.assemble(request: softBandRequest) { input in
            fatalError("transform must not run under hard threshold")
        }
        #expect(softResult.preCompactionMemoryFlush == nil)
        #expect(await stubRunner.callCount == 0)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("DefaultContextEngine omits pre-compaction memory flush spec when disabled")
    func engineOmitsPreCompactionMemoryFlushWhenDisabled() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let request = ContextEngineAssembleRequest(
            messages: [Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])],
            conversation: conv,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
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
            preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput(
                enabled: false,
                maxFlushedMemoryEntries: 16
            )
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(result.preCompactionMemoryFlush == nil)
    }

    @Test("DefaultContextEngine prepareSubagentSpawn emits deterministic handoff fingerprint")
    func prepareSubagentSpawnDeterministicFingerprint() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conversationID = UUID()
        let runID = UUID()
        let request = ContextEnginePrepareSubagentSpawnRequest(
            conversationID: conversationID,
            runID: runID,
            candidateToolNames: ["delegate.alpha", "delegate.beta"],
            permissionPolicyByToolName: [
                "delegate.alpha": .auto,
                "delegate.beta": .askUser,
            ],
            trustLevelByToolName: [
                "delegate.alpha": .system,
                "delegate.beta": .knownParty,
            ],
            preApprovedToolNames: Set(["delegate.beta"])
        )
        let first = await engine.prepareSubagentSpawn(request: request)
        let second = await engine.prepareSubagentSpawn(request: request)
        #expect(first.approvedToolNames == second.approvedToolNames)
        #expect(first.handoffArtifact?.policyFingerprint == second.handoffArtifact?.policyFingerprint)
        #expect(first.checkpointInvalidation?.invalidatedKinds == second.checkpointInvalidation?.invalidatedKinds)
    }

    @Test("DefaultContextEngine onSubagentEnded invalidates attachment projection for non-system trust")
    func onSubagentEndedNonSystemTrustInvalidation() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let result = await engine.onSubagentEnded(
            request: ContextEngineSubagentEndedRequest(
                conversationID: UUID(),
                runID: UUID(),
                toolName: "delegate.remote",
                permissionPolicy: .askUser,
                trustLevel: .unknownParty
            )
        )
        #expect(result.acknowledged)
        #expect(result.checkpointInvalidation?.invalidatedKinds.contains(HarnessCheckpointInvalidationKind.memoryInjectionSnapshot) == true)
        #expect(result.checkpointInvalidation?.invalidatedKinds.contains(HarnessCheckpointInvalidationKind.attachmentProjection) == true)
    }

    @Test("DefaultContextEngine skips checkpoint persistence when savings below threshold")
    func engineSkipsPersistenceWhenSavingsBelowThreshold() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let chunk = String(repeating: "z", count: 4_000)
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ]
        for idx in 0..<12 {
            messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest", timestamp: Date(), toolCalls: []))
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.compactionMinPromptTokenSavingsFraction = 0.5
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: compactionConfig,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 2_500,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0
        )
        let result = await engine.assemble(request: request) { input in
            ContextTransformOutput(
                messages: input.messages,
                diagnostics: ContextCompactionTransformer.prunedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(result.compactionLowSavings)
        #expect(result.checkpointPersistence == nil)
        #expect(result.transformOutput?.diagnostics == ContextCompactionTransformer.prunedDiagnostic)
    }

    @Test("DefaultContextEngine savings check ignores stale lastPromptTokens")
    func engineSavingsCheckIgnoresStaleLastPromptTokens() async {
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "s"
        )
        let messages = longCompactionThreadForEngineTests()
        var compactionConfig = ContextCompactionConfiguration.default
        compactionConfig.compactionMinPromptTokenSavingsFraction = 0.03
        compactionConfig.middleMinCharactersForCompactionLLM = 0
        let request = ContextEngineAssembleRequest(
            messages: messages,
            conversation: conv,
            phase: .initial,
            gatingOverride: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true),
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: compactionConfig,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conv.id,
                modelID: conv.model.id.uuidString,
                modelName: conv.model.modelName,
                interactionMode: .chat,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: 2_500,
            lastPromptTokens: 8_000,
            events: [],
            eventLogFrontier: 0,
            lastLLMDateByConversationID: [:],
            persistCompactionCheckpoint: true,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0
        )
        let result = await engine.assemble(request: request) { input in
            var outputMessages = input.messages
            var bytesToDrop = 3_000
            for index in outputMessages.indices.reversed() where bytesToDrop > 0 && outputMessages[index].content.count > 64 {
                let drop = min(bytesToDrop, outputMessages[index].content.count - 32)
                outputMessages[index] = Message(
                    id: outputMessages[index].id,
                    role: outputMessages[index].role,
                    content: String(outputMessages[index].content.dropLast(drop)),
                    timestamp: outputMessages[index].timestamp,
                    toolCalls: outputMessages[index].toolCalls,
                    toolCallId: outputMessages[index].toolCallId
                )
                bytesToDrop -= drop
            }
            return ContextTransformOutput(
                messages: outputMessages,
                diagnostics: ContextCompactionTransformer.prunedDiagnostic,
                messageProvenance: nil
            )
        }
        #expect(result.compactionLowSavings == false)
        #expect(result.checkpointPersistence != nil)
    }

    private static func longTranscriptForFlushTests() -> [Message] {
        let longBody = String(repeating: "token ", count: 8000)
        var messages: [Message] = []
        for index in 0..<12 {
            messages.append(Message(id: UUID(), role: .user, content: "\(longBody) user \(index)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "\(longBody) assistant \(index)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest user", timestamp: Date(), toolCalls: []))
        return messages
    }
}

private func longCompactionThreadForEngineTests() -> [Message] {
    var messages: [Message] = [
        Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
    ]
    let chunk = String(repeating: "z", count: 4_000)
    for idx in 0..<12 {
        messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
    }
    messages.append(Message(id: UUID(), role: .user, content: "latest", timestamp: Date(), toolCalls: []))
    return messages
}

private actor TransformCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor StubPreCompactionFlushRunner: PreCompactionMemoryFlushRunning {
    let result: PreCompactionMemoryFlushResult
    private(set) var lastContext: PreCompactionMemoryFlushContext?
    private(set) var callCount = 0

    init(result: PreCompactionMemoryFlushResult) {
        self.result = result
    }

    func runSilentFlushIfNeeded(
        context: PreCompactionMemoryFlushContext,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult {
        _ = logger
        callCount += 1
        lastContext = context
        return result
    }
}

private actor ProviderPreCompressNoteCapture {
    private(set) var value: String?
    func set(_ notes: String?) {
        value = notes
    }
}

private struct StubPreCompressMemoryRuntime: MemoryRuntime {
    let note: String

    func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
        _ = sessionID
        _ = context
    }

    func endSession(conversationID: UUID) async { _ = conversationID }

    func shutdown() async {}

    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
        _ = request
        return MemoryRecallResult(selectedFilenames: [], hits: [])
    }

    func recallHits(selectionKeys: [String], session: MemorySessionContext) async throws -> MemoryRecallResult {
        _ = selectionKeys
        _ = session
        return MemoryRecallResult(selectedFilenames: [], hits: [])
    }

    func onTurnEnded(request: MemoryTurnEndedRequest) async { _ = request }

    func onPreCompress(messages: [String]) async -> String {
        _ = messages
        return note
    }

    func refreshSnapshotAfterFlush(conversationID: UUID) async throws { _ = conversationID }

    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
        _ = conversationID
        return nil
    }

    func currentSnapshotGeneration(conversationID: UUID) async -> Int {
        _ = conversationID
        return 1
    }

    func invalidateSnapshot(conversationID: UUID) async { _ = conversationID }

    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
        _ = conversationID
        return []
    }

    func hybridSearch() async -> HybridMemorySearch { HybridMemorySearch() }

    func updateSnapshot(
        conversationID: UUID,
        blocks: MemorySystemPromptBlocks,
        manifest: [MemoryManifestEntry]
    ) async {
        _ = conversationID
        _ = blocks
        _ = manifest
    }

    func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws {
        _ = memoryDirectory
        _ = rollback
    }

    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async { _ = port }

    func drainPendingWork(timeoutMs: Int) async { _ = timeoutMs }

    func store(for conversationID: UUID) async -> AgentMemoryStore? {
        _ = conversationID
        return nil
    }

    func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
        _ = conversationID
        return nil
    }

    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String> = []
    ) async -> ActiveMemoryRecallOutcome {
        _ = session
        _ = messages
        _ = anchorUserMessageID
        _ = sessionEnabled
        _ = excludedSelectionKeys
        return .skipped(reason: "stub", queryMode: .recent)
    }

    func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool) async {
        _ = session
        _ = sessionEnabled
    }

    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async {
        _ = session
        _ = messages
        _ = anchorUserMessageID
        _ = sessionEnabled
    }

    func invalidateStandingRecall(conversationID: UUID) async { _ = conversationID }
}

private struct StubPreCompressMemoryProvider: MemoryProviding {
    let note: String

    func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
        _ = sessionID
        _ = context
    }

    func systemPromptBlock() async -> String { "" }

    func prefetch(query: String) async -> String? {
        _ = query
        return nil
    }

    func queuePrefetch(query: String) async {
        _ = query
    }

    func syncTurn(userContent: String, assistantContent: String) async {
        _ = userContent
        _ = assistantContent
    }

    func onPreCompress(messages: [String]) async -> String {
        _ = messages
        return note
    }

    func onSessionEnd(messages: [String]) async {
        _ = messages
    }

    func shutdown() async {}
}
