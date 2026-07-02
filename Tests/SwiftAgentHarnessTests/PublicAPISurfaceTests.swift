import Foundation
import Logging
import SwiftAgentKit
import Testing
import SwiftAgentHarness

@Suite("Public API surface (non-testable import)")
struct PublicAPISurfaceTests {
    @Test("SubAgentHostingPolicy is constructible with public members")
    func subAgentHostingPolicy() {
        let policy = SubAgentHostingPolicy(
            hostPersonaID: "host",
            delegationAllowlist: ["delegate-tool"],
            authScopeTags: ["scope"],
            routingDomain: "example.com",
            tenantScope: "tenant-a"
        )
        #expect(policy.hostPersonaID == "host")
        #expect(policy.delegationAllowlist == ["delegate-tool"])
    }

    @Test("SessionEntryID.generate is callable")
    func sessionEntryIDGenerate() {
        let id = SessionEntryID.generate()
        #expect(id.rawValue.count == 8)
    }

    @Test("Context compaction exports are constructible")
    func contextCompactionExports() {
        let config = ContextCompactionConfiguration.default
        let cachePolicy = ContextCompactionCachePolicy(
            enabled: true,
            stablePrefixMessageCount: 4,
            ttlSeconds: 60
        )
        let attachmentHygiene = ContextCompactionAttachmentDocumentHygienePolicy(
            enabled: true,
            maxImagesPerMessage: 2,
            documentCharacterThreshold: 500,
            imagePlaceholder: "[image]",
            documentPlaceholder: "[document]"
        )
        let hygiene = ContextCompactionDeterministicHygienePolicy(
            toolResultPruningEnabled: true,
            attachmentDocumentHygiene: attachmentHygiene
        )
        let identifierPreservation = ContextCompactionIdentifierPreservationPolicy(
            mode: .strict,
            customInstructions: nil
        )
        let memoryFlush = ContextEnginePreCompactionMemoryFlushPolicyInput(
            enabled: false,
            maxFlushedMemoryEntries: 32
        )
        let scheduling = ContextCompactionLLMScheduling(
            scheduler: ModelCallScheduler(),
            modelID: UUID()
        )
        let transformer = ContextCompactionTransformer.makeProduction(
            config: config,
            scheduling: scheduling
        )
        #expect(cachePolicy.enabled)
        #expect(hygiene.toolResultPruningEnabled)
        #expect(identifierPreservation.mode == .strict)
        #expect(memoryFlush.maxFlushedMemoryEntries == 32)
        #expect(transformer is ContextCompactionTransformer)
        #expect(ContextCompactionPolicy.resolvedCachePolicy(config: config).enabled == config.cacheAwarePruningEnabled)
        #expect(ContextCompactionPolicy.resolvedDeterministicHygienePolicy(config: config).toolResultPruningEnabled == config.deterministicToolResultPruningEnabled)
    }

    @Test("ModelManager and ModelPoolCostLedger initializers are public")
    func modelPoolExports() async {
        let manager = ModelManager(
            logger: Logger(label: "public-api-test"),
            authProfileStore: AuthProfileStore(environment: [:])
        )
        let ledger = ModelPoolCostLedger()
        _ = await manager.getAvailableModels()
        await ledger.setConversationMaxUSD(conversationID: UUID(), maxUSD: 1.0)
    }

    @Test("APILayer wiring entry points are public")
    func apiLayerWiring() async throws {
        let api = APILayer(port: 0)
        let manager = ModelManager(authProfileStore: AuthProfileStore(environment: [:]))
        await api.setModelManager(manager)
        await api.setBudgetReporting(NilBudgetReporting())
        await api.stop()
    }

    @Test("Session persistence configuration env accessors are public")
    func sessionPersistenceConfiguration() {
        _ = SessionPersistenceConfiguration.harnessOnDiskV2Configured
        _ = SessionPersistenceConfiguration.sessionAgentId
    }

    @Test("CompactionConcurrencyCoordinator is public")
    func compactionCoordinator() async {
        let coordinator = CompactionConcurrencyCoordinator()
        let acquired = await coordinator.tryAcquire(for: UUID())
        #expect(acquired)
        await coordinator.release(for: UUID())
    }

    @Test("Second-batch public wiring types are constructible")
    func secondBatchExports() {
        _ = ModeRegistryPortAdapter(service: ModeRegistryService())
        _ = DefaultContextEngine()
        _ = AgentRuntimeExecutorFactories.default
        _ = AgentRuntimeTurnConfiguration(enableTools: true)
        _ = HTTPPreconditionPolicySettings(strictMode: true)
        _ = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: false)
        _ = APIAccessTokenAuthenticationSettings(hs256Secret: "secret")
        _ = TriggerTaskRunPorts(
            append: { _, _, _ in UUID() },
            latestUndelivered: { _ in nil },
            markDelivered: { _ in }
        )
        _ = TriggersRuntimeWiring.Configuration(dataDirectory: URL(fileURLWithPath: "/tmp"))
        let trigger = HarnessTrigger(
            id: "t1",
            source: .api,
            payload: "hello",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        _ = TriggerHostConversationMetadata.stampHostMetadata(
            existing: nil,
            trigger: trigger,
            sessionKey: "session-key"
        )
        let record = SessionHarnessTaskRunRecord(
            runId: UUID(),
            jobId: "job",
            createdAt: Date(),
            payload: Data(),
            idempotencyKey: nil
        )
        #expect(record.jobId == "job")
    }

    @Test("Third-batch public wiring types and members are accessible")
    func thirdBatchExports() async throws {
        let memory = MemoryConfiguration.default
        #expect(memory.recallSelectorModel == MemoryConfiguration.default.recallSelectorModel)
        _ = ModelPoolMemoryLLMRecallSelector(
            scheduler: ModelCallScheduler(),
            modelName: memory.recallSelectorModel,
            serverURL: memory.recallSelectorOllamaServerURL
        )
        _ = DerivedArtifactRetentionPolicy()
        _ = ContextCompactionPreviewAPISettings(isRouteEnabled: false, authToken: nil)
        _ = ConversationTopicWireEncoding.messagesRefreshPayload(messages: [])
        _ = TranscriptLockSignalRegistry.shared
        let modeRegistry = ModeRegistryService()
        await modeRegistry.setOnDidMutate {}
        _ = try await modeRegistry.resolve(modeId: InteractionMode.chat.rawValue)
        _ = await modeRegistry.configurationDiagnostics()
        let api = APILayer(port: 0)
        await api.setContextCompactionPreviewSettings(.disabled)
        await api.setWebSocketOutboundFlowConfiguration(WebSocketOutboundFlowConfiguration())
        await api.stop()
    }

    @Test("Fourth-batch public wiring types and members are accessible")
    func fourthBatchExports() {
        _ = TriggersRuntimeWiring.DelegatedPorts(
            spawnSubAgent: { _, _, _ in UUID() },
            sendMessageAndRun: { _, _ in },
            lastAssistantText: { _ in nil },
            stampDelegatedHost: { _, _, _ in },
            resolveParentConversation: { _ in nil }
        )
        _ = SessionPersistenceConfiguration.transcriptVerifyPeriodicEnabled
        _ = SessionPersistenceConfiguration.transcriptVerifyPeriodicIntervalSeconds
    }

    @Test("Fifth-batch startup and shutdown members are accessible")
    func fifthBatchExports() async {
        let report = SessionTranscriptIntegrityReport(
            conversationCount: 0,
            autoRepairedCount: 0,
            quarantinedCount: 0,
            verifyFailedCount: 0,
            severity: .normal,
            samples: []
        )
        let checkSession: @Sendable (HarnessRuntimeSession) async throws -> Void = { session in
            try await session.resetConversationsFromCatalog(availableModels: [])
            await session.refreshTranscriptIntegrityFlagsAfterMaintenance(report: report)
            await session.shutdown()
        }
        let checkStartup: @Sendable (ConversationStartupService, HarnessRuntimeSession) async throws -> Void = { startup, session in
            try await startup.resetConversationsFromCatalog(availableModels: [])
            await startup.refreshTranscriptIntegrityFlagsAfterMaintenance(report: report)
            await startup.shutdown(
                agentRuntime: session.agentRuntimeSessionService,
                conversationReplay: session.conversationReplayService,
                orchestratorRuntime: session.orchestratorRuntimeService
            )
            await startup.shutdownOrchestratorAndToolRuntimes(
                agentRuntime: session.agentRuntimeSessionService,
                conversationReplay: session.conversationReplayService,
                orchestratorRuntime: session.orchestratorRuntimeService
            )
        }
        _ = (checkSession, checkStartup)
    }

    @Test("Sixth-batch services, session, spawn, and split gateway exports are accessible")
    func sixthBatchExports() async {
        let checkServices: @Sendable (HarnessRuntimeSessionFactory.Services) -> Void = { services in
            _ = services.conversationStartupService
            _ = services.subAgentSpawnService
            _ = services.subAgentCompletionRuntimeService
            _ = services.channelRegistryHolder
        }
        let checkSession: @Sendable (HarnessRuntimeSession) async throws -> Void = { session in
            _ = await session.subAgentSpawnService
            _ = await session.subAgentCompletionRuntimeService
            _ = try await session.serviceHarnessDedupePeek(key: "k")
            _ = try await session.serviceHarnessDedupeCheckAndSet(key: "k", ttlSeconds: 60)
            _ = try await session.serviceResolveConversationByTitle("title")
            _ = await session.modelConversation(id: UUID())
            let createConversation: @Sendable (HarnessRuntimeSession, Model) async throws -> UUID = { session, model in
                try await session.createConversation(with: model, userSystemPrompt: "sys")
            }
            _ = createConversation
            let trigger = HarnessTrigger(
                id: "t1",
                source: .api,
                payload: "hello",
                initiator: TriggerInitiator(kind: .external),
                trust: .knownParty
            )
            try await session.stampTriggerHostConversation(
                conversationID: UUID(),
                trigger: trigger,
                sessionKey: "session-key"
            )
        }
        let checkSpawn: @Sendable (SubAgentSpawnService) async throws -> Void = { spawn in
            _ = try await spawn.spawnSubAgentViaPool(
                parentConversationID: UUID(),
                request: SubAgentSpawnRequest(context: .isolated, taskDescription: "task"),
                modelOverride: nil,
                bypassDelegateAllowList: true
            )
        }
        let checkSplitGateway: @Sendable (HarnessRuntimeGraph) -> Void = { graph in
            _ = SplitGatewayServiceFactory.makeConversationAdapter(runtimeGraph: graph)
        }
        _ = (checkServices, checkSession, checkSpawn, checkSplitGateway)
    }
}
