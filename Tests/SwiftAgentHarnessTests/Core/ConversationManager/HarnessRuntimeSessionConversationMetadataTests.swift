import Foundation
import EasyJSON
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum HarnessRuntimeSessionConversationMetadataTestSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(
        name: String = "metadata:test",
        modelProtocol: ModelProtocol = .openAIAPI,
        capabilities: [LLMCapability] = [.completion]
    ) -> Model {
        Model(
            protocol: modelProtocol,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: capabilities,
            modelProtocol: modelProtocol
        )
    }

    static func makeHost(
        container: ModelContainer,
        modeRegistry: any ModeRegistryAccessing = ModeRegistryTestSupport.makePort()
    ) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            modeRegistry: modeRegistry
        )
    }
}

@Suite("HarnessRuntimeSession conversation metadata", .serialized)
struct HarnessRuntimeSessionConversationMetadataTests {
    private func encodedMetadata(_ metadata: JSON?) throws -> Data {
        try JSONEncoder().encode(metadata)
    }

    @Test("createConversation persists topic and description to cache and in-memory conversation")
    func createConversationPersistsMetadata() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel()
        let metadata: JSON = .object(["source": .string("tests")])

        try await runtimeSession.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "Weekly planning",
            description: "Review and prioritize weekly tasks.",
            metadata: metadata
        )

        let createdConversationID = try #require(await runtimeSession.currentConversationID)
        let inMemoryConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == createdConversationID }))
        let inMemoryCreatedAt = inMemoryConversation.createdAt
        #expect(inMemoryConversation.topic == "Weekly planning")
        #expect(inMemoryConversation.description == "Review and prioritize weekly tasks.")
        #expect(try encodedMetadata(inMemoryConversation.metadata) == encodedMetadata(metadata))
        #expect(inMemoryCreatedAt <= inMemoryConversation.updatedAt)

        let reloadedHarnessRuntimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloadedHarnessRuntimeSession.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConversation = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == createdConversationID }))
        #expect(reloadedConversation.topic == "Weekly planning")
        #expect(reloadedConversation.description == "Review and prioritize weekly tasks.")
        #expect(try encodedMetadata(reloadedConversation.metadata) == encodedMetadata(metadata))
        #expect(abs(reloadedConversation.createdAt.timeIntervalSince(inMemoryCreatedAt)) < 1)
    }

    @Test("createConversation initializes thinkingEnabled from model capability")
    func createConversationInitializesThinkingPreference() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let thinkingModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "thinking:test",
            capabilities: [.completion, .thinking]
        )
        let nonThinkingModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "non-thinking:test",
            capabilities: [.completion]
        )

        try await runtimeSession.createConversation(with: thinkingModel, userSystemPrompt: "sys")
        let thinkingID = try #require(await runtimeSession.currentConversationID)
        let thinkingConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == thinkingID }))
        #expect(thinkingConversation.thinkingEnabled == true)

        try await runtimeSession.createConversation(with: nonThinkingModel, userSystemPrompt: "sys")
        let nonThinkingID = try #require(await runtimeSession.currentConversationID)
        let nonThinkingConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == nonThinkingID }))
        #expect(nonThinkingConversation.thinkingEnabled == false)

        let reloadedHarnessRuntimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloadedHarnessRuntimeSession.resetConversationsFromCatalog(availableModels: [thinkingModel, nonThinkingModel])
        let reloadedThinking = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == thinkingID }))
        let reloadedNonThinking = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == nonThinkingID }))
        #expect(reloadedThinking.thinkingEnabled == true)
        #expect(reloadedNonThinking.thinkingEnabled == false)
    }

    @Test("copyConversation initializes thinkingEnabled from destination model capability")
    func copyConversationInitializesThinkingPreferenceFromTargetModel() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let sourceModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "source-thinking:test",
            capabilities: [.completion, .thinking]
        )
        let targetModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "target-non-thinking:test",
            capabilities: [.completion]
        )

        try await runtimeSession.createConversation(with: sourceModel, userSystemPrompt: "sys")
        let sourceID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.copyConversation(from: sourceID, to: targetModel, systemPrompt: "copied")
        let copiedID = try #require(await runtimeSession.currentConversationID)
        let copiedConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == copiedID }))
        #expect(copiedConversation.model.id == targetModel.id)
        #expect(copiedConversation.thinkingEnabled == false)
    }

    @Test("createConversation initializes reasoningEffort for OpenAI thinking models only")
    func createConversationInitializesReasoningEffort() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let openAIThinking = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "openai-thinking:test",
            modelProtocol: .openAIAPI,
            capabilities: [.completion, .thinking]
        )
        let openAINonThinking = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "openai-non-thinking:test",
            modelProtocol: .openAIAPI,
            capabilities: [.completion]
        )
        let ollamaThinking = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "ollama-thinking:test",
            modelProtocol: .ollama,
            capabilities: [.completion, .thinking]
        )

        try await runtimeSession.createConversation(with: openAIThinking, userSystemPrompt: "sys")
        let openAIThinkingID = try #require(await runtimeSession.currentConversationID)
        let openAIThinkingConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == openAIThinkingID }))
        #expect(openAIThinkingConversation.reasoningEffort == .medium)

        try await runtimeSession.createConversation(with: openAINonThinking, userSystemPrompt: "sys")
        let openAINonThinkingID = try #require(await runtimeSession.currentConversationID)
        let openAINonThinkingConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == openAINonThinkingID }))
        #expect(openAINonThinkingConversation.reasoningEffort == nil)

        try await runtimeSession.createConversation(with: ollamaThinking, userSystemPrompt: "sys")
        let ollamaThinkingID = try #require(await runtimeSession.currentConversationID)
        let ollamaThinkingConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == ollamaThinkingID }))
        #expect(ollamaThinkingConversation.reasoningEffort == nil)
    }

    @Test("copyConversation initializes reasoningEffort from destination model")
    func copyConversationInitializesReasoningEffortFromTargetModel() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let sourceModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "source-openai-thinking:test",
            modelProtocol: .openAIAPI,
            capabilities: [.completion, .thinking]
        )
        let targetModel = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(
            name: "target-openai-thinking:test",
            modelProtocol: .openAIAPI,
            capabilities: [.completion, .thinking]
        )

        try await runtimeSession.createConversation(with: sourceModel, userSystemPrompt: "sys")
        let sourceID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.copyConversation(from: sourceID, to: targetModel, systemPrompt: "copied")
        let copiedID = try #require(await runtimeSession.currentConversationID)
        let copiedConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == copiedID }))
        #expect(copiedConversation.reasoningEffort == .medium)
    }

    @Test("resetConversationsFromCatalog hydrates topic and description from cache")
    func resetConversationsHydratesMetadata() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "metadata-hydrate")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "hydrate:test")
        let seededCreatedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let conversationID = UUID()
        var record = SessionCatalogRecord(
            id: conversationID,
            topic: "Hydrated topic",
            description: "Hydrated description",
            messageCount: 0,
            updatedAt: seededCreatedAt,
            createdAt: seededCreatedAt,
            modelName: model.modelName,
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        record.metadataJSON = "{\"source\":\"seed\"}"
        record.systemPrompt = "sys"
        try fixture.local.bootstrapEmptyConversation(record)
        let sys = Message(id: UUID(), role: .system, content: "sys", timestamp: seededCreatedAt, toolCalls: [])
        _ = try await fixture.stack.saveMessage(sys, for: conversationID, resourceManager: nil, logger: nil)
        try fixture.stack.conversationManager.resetConversationsFromCatalog(availableModels: [model])

        let runtimeSession = fixture.host
        try await runtimeSession.resetConversationsFromCatalog(availableModels: [model])

        let hydratedConversation = try #require(await runtimeSession.listConversationInfo().first)
        #expect(hydratedConversation.topic == "Hydrated topic")
        #expect(hydratedConversation.description == "Hydrated description")
        #expect(try encodedMetadata(hydratedConversation.metadata) == encodedMetadata(.object(["source": .string("seed")])))
        #expect(hydratedConversation.createdAt == seededCreatedAt)
    }

    @Test("updateConversationMetadata updates topic and description in memory and cache")
    func updateConversationMetadataPersistsChanges() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "update:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: "Updated Topic",
            description: "Updated Description",
            metadata: .object(["source": .string("update-route")])
        )

        let updatedInMemory = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(updatedInMemory.topic == "Updated Topic")
        #expect(updatedInMemory.description == "Updated Description")
        #expect(try encodedMetadata(updatedInMemory.metadata) == encodedMetadata(.object(["source": .string("update-route")])))

        let reloadedHarnessRuntimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloadedHarnessRuntimeSession.resetConversationsFromCatalog(availableModels: [model])
        let reloadedConversation = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(reloadedConversation.topic == "Updated Topic")
        #expect(reloadedConversation.description == "Updated Description")
        #expect(try encodedMetadata(reloadedConversation.metadata) == encodedMetadata(.object(["source": .string("update-route")])))
    }

    @Test("updateConversationMetadata trims and clears empty values")
    func updateConversationMetadataClearsEmptyValues() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "clear:test")

        try await runtimeSession.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "Initial Topic",
            description: "Initial Description"
        )
        let conversationID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: "   ",
            description: ""
        )

        let updatedConversation = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(updatedConversation.topic == nil)
        #expect(updatedConversation.description == nil)
    }

    @Test("updateConversationMetadata can change interaction mode and persists to cache")
    func updateConversationMetadataChangesInteractionMode() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "mode:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .chat)
        let conversationID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: nil,
            description: nil,
            interactionMode: .plan
        )

        let afterPlan = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(afterPlan.interactionMode == .plan)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: nil,
            description: nil,
            interactionMode: .agent
        )
        let afterAgent = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(afterAgent.interactionMode == .agent)

        let transcriptEntries = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiReadTranscriptEntries(
            conversationID: conversationID,
            request: .full
        )
        let modeMarkers = transcriptEntries
            .filter { $0.type == .conversationJournal }
            .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
            .filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        #expect(modeMarkers.count == 2)
        let firstPayload = try #require(
            ConversationEventCodec.decode(
                InteractionModeChangedEventPayload.self,
                from: modeMarkers[0].innerPayloadJSON
            )
        )
        #expect(firstPayload.fromProfileID == InteractionMode.chat.rawValue)
        #expect(firstPayload.toProfileID == InteractionMode.plan.rawValue)
        #expect(firstPayload.fromMode == InteractionMode.chat.rawValue)
        #expect(firstPayload.toMode == InteractionMode.plan.rawValue)

        let secondPayload = try #require(
            ConversationEventCodec.decode(
                InteractionModeChangedEventPayload.self,
                from: modeMarkers[1].innerPayloadJSON
            )
        )
        #expect(secondPayload.fromProfileID == InteractionMode.plan.rawValue)
        #expect(secondPayload.toProfileID == InteractionMode.agent.rawValue)
        #expect(secondPayload.fromMode == InteractionMode.plan.rawValue)
        #expect(secondPayload.toMode == InteractionMode.agent.rawValue)

        let reloadedHarnessRuntimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloadedHarnessRuntimeSession.resetConversationsFromCatalog(availableModels: [model])
        let reloaded = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(reloaded.interactionMode == .agent)
    }

    @Test("modeProfileID persists and reloads for arbitrary custom ids")
    func modeProfileIDRoundTripPersists() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "mode-profile-id:test")

        try await runtimeSession.createConversation(
            with: model,
            userSystemPrompt: "sys",
            interactionMode: .chat,
            modeProfileID: "custom.profile.alpha"
        )
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let created = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(created.modeProfileID == "custom.profile.alpha")
        #expect(created.interactionMode == .chat)

        let reloaded = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let hydrated = try #require(await reloaded.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(hydrated.modeProfileID == "custom.profile.alpha")
        #expect(hydrated.interactionMode == .chat)
    }

    @Test("mode transition rejects while run is active")
    func modeTransitionRejectsDuringActiveRun() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "mode-active-run:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .chat)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.currentConversation())
        await runtimeSession.testing_ensureOrchestratorPoolEntry(model: model, conversation: conversation)
        let activeRunID = UUID()
        await runtimeSession.testing_setActiveStreamingRun(conversationID: conversationID, runID: activeRunID)
        defer {
            Task {
                await runtimeSession.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
            }
        }

        await #expect(throws: ConversationServiceError.self) {
            try await runtimeSession.updateConversationMetadata(
                conversationID: conversationID,
                topic: nil,
                description: nil,
                interactionMode: .plan,
                interactionModeChangeInitiator: "api"
            )
        }
    }

    @Test("tool mode transition defers while run is active then applies on natural stop")
    func toolModeTransitionDefersUntilRunCompletes() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "mode-defer:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .plan)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.currentConversation())
        await runtimeSession.testing_ensureOrchestratorPoolEntry(model: model, conversation: conversation)
        let activeRunID = UUID()
        await runtimeSession.testing_setActiveStreamingRun(conversationID: conversationID, runID: activeRunID)
        defer {
            Task {
                await runtimeSession.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
            }
        }

        let outcome = try await runtimeSession.conversationDomainServices.controlPlane.scheduleOrApplyToolModeTransition(
            conversationID: conversationID,
            targetMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue,
            reason: ModeTransitionToolProvider.exitPlanModeToolName
        )
        #expect(outcome == .deferredUntilRunCompletes)

        let stillPlan = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(stillPlan.interactionMode == .plan)

        await runtimeSession.conversationDomainServices.controlPlane.flushPendingModeTransition(
            conversationID: conversationID,
            runID: activeRunID,
            terminalCategory: .naturalStop
        )

        let afterFlush = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(afterFlush.interactionMode == .agent)
    }

    @Test("deferred tool mode transition is discarded on cancelled run")
    func deferredToolModeTransitionDiscardedOnCancel() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "mode-defer-cancel:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .plan)
        let conversationID = try #require(await runtimeSession.currentConversationID)
        let conversation = try #require(await runtimeSession.currentConversation())
        await runtimeSession.testing_ensureOrchestratorPoolEntry(model: model, conversation: conversation)
        let activeRunID = UUID()
        await runtimeSession.testing_setActiveStreamingRun(conversationID: conversationID, runID: activeRunID)
        defer {
            Task {
                await runtimeSession.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
            }
        }

        let outcome = try await runtimeSession.conversationDomainServices.controlPlane.scheduleOrApplyToolModeTransition(
            conversationID: conversationID,
            targetMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue,
            reason: ModeTransitionToolProvider.exitPlanModeToolName
        )
        #expect(outcome == .deferredUntilRunCompletes)

        await runtimeSession.conversationDomainServices.controlPlane.flushPendingModeTransition(
            conversationID: conversationID,
            runID: activeRunID,
            terminalCategory: .externalCancellation
        )

        let stillPlan = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(stillPlan.interactionMode == .plan)
    }

    @Test("profile-only mode transition appends interaction_mode_changed marker")
    func profileOnlyTransitionAppendsModeMarker() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "custom-chat-profile",
                    extends: InteractionMode.chat.rawValue,
                    hooks: .object([
                        "onExit": .array([]),
                        "onEnter": .array([]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: config)
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container, modeRegistry: registry)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "profile-only:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .chat)
        let conversationID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: nil,
            description: nil,
            modeProfileID: "custom-chat-profile"
        )

        let updated = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(updated.interactionMode == .chat)
        #expect(updated.modeProfileID == "custom-chat-profile")

        let transcriptEntries = try await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiReadTranscriptEntries(
            conversationID: conversationID,
            request: .full
        )
        let modeMarkers = transcriptEntries
            .filter { $0.type == .conversationJournal }
            .compactMap { try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON) }
            .filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        #expect(modeMarkers.count == 1)
        let payload = try #require(
            ConversationEventCodec.decode(
                InteractionModeChangedEventPayload.self,
                from: modeMarkers[0].innerPayloadJSON
            )
        )
        #expect(payload.fromMode == InteractionMode.chat.rawValue)
        #expect(payload.toMode == InteractionMode.chat.rawValue)
        #expect(payload.fromProfileID == InteractionMode.chat.rawValue)
        #expect(payload.toProfileID == "custom-chat-profile")
    }

    @Test("mode transition hook failure rolls back persisted conversation state")
    func modeTransitionHookFailureRollsBackState() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "broken-plan-profile",
                    extends: InteractionMode.plan.rawValue,
                    hooks: .object([
                        "onEnter": .array([.string("unknown_hook_id")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makePort(seedingBuiltIns: true, modeProfileConfiguration: config)
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container, modeRegistry: registry)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "broken-hook:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .chat)
        let conversationID = try #require(await runtimeSession.currentConversationID)

        await #expect(throws: ConversationServiceError.self) {
            try await runtimeSession.updateConversationMetadata(
                conversationID: conversationID,
                topic: nil,
                description: nil,
                modeProfileID: "broken-plan-profile"
            )
        }

        let afterFailure = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(afterFailure.interactionMode == .chat)
        #expect(afterFailure.modeProfileID == InteractionMode.chat.rawValue)

        let journal = ConversationEventLogService(container: container)
        let (events, _) = journal.loadConversationEventsWithFrontier(conversationID: conversationID)
        let modeMarkers = events.filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        #expect(modeMarkers.isEmpty)
    }

    @Test("updateConversationMetadata with interactionMode only persists to SwiftData")
    func updateConversationMetadataInteractionModeOnlyPersistsInteractionMode() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "phase-only:test")

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .plan)
        let conversationID = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.updateConversationMetadata(
            conversationID: conversationID,
            topic: nil,
            description: nil,
            interactionMode: .agent
        )

        let afterBuild = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(afterBuild.interactionMode == .agent)

        let reloadedHarnessRuntimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloadedHarnessRuntimeSession.resetConversationsFromCatalog(availableModels: [model])
        let reloaded = try #require(await reloadedHarnessRuntimeSession.listConversationInfo().first(where: { $0.id == conversationID }))
        #expect(reloaded.interactionMode == .agent)
    }

    @Test("updateConversationMetadata preserves activatedAgentSkillNames when omitted from incoming metadata")
    func updateConversationMetadataPreservesActivatedSkillsKey() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "skills-meta:test")
        let initial: JSON = .object([
            "activatedAgentSkillNames": .array([.string("my-skill")]),
            "source": .string("initial"),
        ])
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", metadata: initial)
        let id = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.updateConversationMetadata(
            conversationID: id,
            topic: nil,
            description: nil,
            metadata: .object(["other": .string("only")])
        )
        let conv = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: conv.metadata) == ["my-skill"])
        guard case .object(let dict) = conv.metadata else {
            Issue.record("metadata should be object")
            return
        }
        guard case .string("only") = dict["other"] else {
            Issue.record("expected other=only")
            return
        }
    }

    @Test("selectConversation preserves per-conversation activatedAgentSkillNames when skill loader is unavailable")
    func selectConversationPreservesActivatedSkillsMetadataWithoutLoader() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel()

        let metaA: JSON = .object([
            "activatedAgentSkillNames": .array([.string("skill-a")]),
        ])
        let metaB: JSON = .object([
            "activatedAgentSkillNames": .array([.string("skill-b")]),
        ])

        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", metadata: metaA)
        let idA = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys2", metadata: metaB)
        let idB = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.selectConversation(conversationID: idA)
        let afterA = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == idA }))
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: afterA.metadata) == ["skill-a"])

        try await runtimeSession.selectConversation(conversationID: idB)
        let bInfo = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == idB }))
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: bInfo.metadata) == ["skill-b"])

        try await runtimeSession.selectConversation(conversationID: idA)
        let aAgain = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == idA }))
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: aAgain.metadata) == ["skill-a"])
    }

    @Test("resetConversationsFromCatalog and selectConversation keep activatedAgentSkillNames in metadata")
    func reloadHydratesActivatedSkillsMetadata() async throws {
        let container = try HarnessRuntimeSessionConversationMetadataTestSupport.makeContainer()
        let model = HarnessRuntimeSessionConversationMetadataTestSupport.makeModel(name: "reload-skills:test")
        let runtimeSession = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        let meta: JSON = .object([
            "activatedAgentSkillNames": .array([.string("persisted-skill")]),
        ])
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", metadata: meta)
        let id = try #require(await runtimeSession.currentConversationID)

        let reloaded = HarnessRuntimeSessionConversationMetadataTestSupport.makeHost(container: container)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        try await reloaded.selectConversation(conversationID: id)
        let conv = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: conv.metadata) == ["persisted-skill"])
    }
}
