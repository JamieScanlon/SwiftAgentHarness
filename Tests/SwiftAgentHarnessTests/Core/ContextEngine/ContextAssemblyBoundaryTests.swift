import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Context assembly boundary (applicator + runtime façade)")
struct ContextAssemblyBoundaryTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func testModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "x",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private func derivedKinds(stack: ConversationPersistenceStack, conversationID: UUID) -> [String] {
        let (events, _) = stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
        return events
            .filter { $0.journalStreamRaw == ConversationJournalStream.derived.rawValue }
            .sorted { $0.eventID < $1.eventID }
            .map(\.kind)
    }

    private func sampleCompactionConfiguration() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
    }

    private func sampleAssembleRequest(conversation: ModelConversation) -> ContextEngineAssembleRequest {
        ContextEngineAssembleRequest(
            messages: [],
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
            derivedTailAtProjectionStart: 0
        )
    }

    private func richAssembleResult(conversationID: UUID, cfg: ContextCompactionConfiguration) -> ContextEngineAssembleResult {
        let mid = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "c", timestamp: Date(), toolCalls: [])
        let memID = UUID()
        let flushID = UUID()
        let attachmentDecision = ConversationAttachmentProjectionDecision(
            attachmentID: UUID(),
            attachmentName: "n",
            attachmentKind: "file",
            disposition: .inline,
            reason: "test"
        )
        return ContextEngineAssembleResult(
            messages: [],
            transformOutput: nil,
            checkpointPersistence: ContextCompactionCheckpointPersistenceSpec(
                conversationID: conversationID,
                rawMiddleMessageIDs: [mid],
                compactedMiddleMessages: [compacted],
                kind: .summarized,
                config: cfg,
                strategyRawValue: nil,
                cachePolicyFingerprint: nil,
                expectedDerivedSequence: nil,
                firstKeptTailMessageID: nil,
                summaryBodyForTranscript: nil,
                promptTokensBeforeCompaction: nil
            ),
            memoryInjectionSnapshot: ContextMemoryInjectionSnapshotSpec(
                conversationID: conversationID,
                phase: .initial,
                memoryStoreVersion: 1,
                memoryStoreNamespaceKey: nil,
                injectedMemoryEntryIDs: [memID]
            ),
            transformFailed: false,
            passthroughReason: nil,
            projectionArtifact: nil,
            systemPromptCheckpoint: ContextSystemPromptAssemblyCheckpointPersistenceSpec(
                conversationID: conversationID,
                fingerprint: "ctx-assembly-test-fingerprint"
            ),
            attachmentProjectionCheckpoint: ContextAttachmentProjectionCheckpointPersistenceSpec(
                conversationID: conversationID,
                projectionFingerprint: "ctx-assembly-att-fp",
                decisions: [attachmentDecision]
            ),
            preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec(
                conversationID: conversationID,
                phase: .initial,
                memoryStoreVersion: 1,
                memoryStoreNamespaceKey: nil,
                flushedMemoryEntryIDs: [flushID]
            )
        )
    }

    @Test("Manual compaction applicator skips system prompt + attachment derived checkpoints")
    func manualScopeSkipsOrchestratorOnlyCheckpoints() async throws {
        let container = try makeContainer()
        let stack = ConversationPersistenceStack.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let cfg = sampleCompactionConfiguration()
        let conversation = ModelConversation(model: testModel(), messages: [], systemPrompt: "s")
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(
            manager: stack.conversationManager,
            conversationID: conversation.id
        )
        let assembleRequest = sampleAssembleRequest(conversation: conversation)
        let result = richAssembleResult(conversationID: conversation.id, cfg: cfg)

        _ = await ContextAssemblyPersistenceApplicator.apply(
            result: result,
            assembleRequest: assembleRequest,
            persistence: stack,
            logger: nil,
            scope: .manualCompaction,
            persistMemoryAndFlushCheckpoints: true
        )

        let kinds = derivedKinds(stack: stack, conversationID: conversation.id)
        #expect(!kinds.contains(ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue))
        #expect(!kinds.contains(ConversationEventKind.attachmentProjectionCheckpoint.rawValue))
        #expect(kinds.contains(ConversationEventKind.contextCompactionCheckpoint.rawValue))
        #expect(kinds.contains(ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue))
    }

    @Test("Orchestrator applicator persists system prompt + attachment derived checkpoints")
    func orchestratorScopePersistsPromptAndAttachmentCheckpoints() async throws {
        let container = try makeContainer()
        let stack = ConversationPersistenceStack.makeForTesting(
            container: container,
            logger: nil,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let cfg = sampleCompactionConfiguration()
        let conversation = ModelConversation(model: testModel(), messages: [], systemPrompt: "s")
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(
            manager: stack.conversationManager,
            conversationID: conversation.id
        )
        let assembleRequest = sampleAssembleRequest(conversation: conversation)
        let result = richAssembleResult(conversationID: conversation.id, cfg: cfg)

        _ = await ContextAssemblyPersistenceApplicator.apply(
            result: result,
            assembleRequest: assembleRequest,
            persistence: stack,
            logger: nil,
            scope: .orchestratorAssemble,
            persistMemoryAndFlushCheckpoints: true
        )

        let kinds = derivedKinds(stack: stack, conversationID: conversation.id)
        #expect(kinds.contains(ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue))
        #expect(kinds.contains(ConversationEventKind.attachmentProjectionCheckpoint.rawValue))
        #expect(kinds.contains(ConversationEventKind.contextCompactionCheckpoint.rawValue))
    }

    @Test("Runtime façade wires event log frontier into assemble request")
    func facadePropagatesEventLogFrontier() async throws {
        let container = try makeContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let facade = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: .default
        )
        let model = testModel()
        let conversation = try await domain.createConversation(
            with: model,
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let msg = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        try await domain.routingAppendMessageJournalEntries(
            conversationID: conversation.id,
            messages: [msg]
        )

        let request = await facade.makeAssembleRequest(
            messages: [msg],
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            projectionPolicy: nil,
            lastContextLimitTokens: nil,
            lastPromptTokens: nil,
            lastContextCompactionLLMDateByConversationID: [:]
        )
        #expect(request.eventLogFrontier == 1)
        #expect(request.events.count >= 1)
    }

    @Test("ContextAssemblyPipeline runs ingest, assemble, and domain persistence for orchestrator scope")
    func pipelineOrchestratorInvokesApplicator() async throws {
        let container = try makeContainer()
        let stack = ConversationPersistenceStack.makeForTesting(container: container, logger: nil)
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let facade = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: .default
        )
        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let conversation = ModelConversation(model: testModel(), messages: [], systemPrompt: "s")
        let msg = Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: [])

        let output = await ContextAssemblyPipeline.ingestAndOrchestratorAssemble(
            contextEngine: engine,
            persistenceDomain: domain,
            runtimeFacade: facade,
            conversationID: conversation.id,
            messages: [msg],
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            projectionPolicy: nil,
            lastContextLimitTokens: nil,
            lastPromptTokens: nil,
            lastContextCompactionLLMDateByConversationID: [:],
            logger: nil,
            performTransform: { input in
                ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
            }
        )
        #expect(output.result.transformFailed == false)
        #expect(output.persistenceEffects.persistedCompactionCheckpoint == false)
        #expect(output.assembleRequest.conversation.id == conversation.id)
    }
}
