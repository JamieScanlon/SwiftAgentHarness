import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor JSONCollector {
    private(set) var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
    }
}

// MARK: - Pool health budget enrichment (composition-style closure)

private final class FixedPoolBudgetReporting: BudgetReporting, Sendable {
    let poolRemaining: Double?
    init(poolRemaining: Double?) { self.poolRemaining = poolRemaining }
    func poolBudgetRemainingUSD() async -> Double? { poolRemaining }
    func projectedCostUSD(conversationID: UUID) async -> Double? { nil }
}

private actor PoolHealthCapture {
    private(set) var last: PoolHealthPayload?
    func record(_ payload: PoolHealthPayload) { last = payload }
}

@Suite("Pool health budget enrichment")
struct PoolHealthBudgetRemainingEnrichmentTests {
    @Test("Stub reporter populates budgetRemaining on enriched broadcast")
    func enrichmentClosurePopulatesBudgetRemaining() async throws {
        let reporter = FixedPoolBudgetReporting(poolRemaining: 42.5)
        let capture = PoolHealthCapture()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 8,
            onPoolHealthChange: { payload in
                var enriched = payload
                enriched.budgetRemaining = await reporter.poolBudgetRemainingUSD()
                await capture.record(enriched)
            }
        )
        let modelID = UUID()
        await scheduler.acquire(for: modelID, priority: .foreground)
        await scheduler.release(for: modelID)
        let snapshot = await capture.last
        #expect(snapshot != nil)
        #expect(snapshot?.budgetRemaining == 42.5)
        #expect(snapshot?.queueDepthByPriority?.foreground == 0)
        #expect(snapshot?.queueDepthByPriority?.background == 0)
    }

    @Test("pool health enrichment includes communication aggregates")
    func enrichmentClosurePopulatesErrorRateAndLatency() async throws {
        let reporter = FixedPoolBudgetReporting(poolRemaining: 1.0)
        let capture = PoolHealthCapture()
        final class Clock: @unchecked Sendable {
            var now: Date
            init(now: Date) { self.now = now }
        }
        let clock = Clock(now: Date(timeIntervalSince1970: 0))
        let aggregates = CommunicationAggregatesEngine(now: { clock.now })
        let coordinator = ModelInvocationCoordinator(communicationAggregates: aggregates)
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        clock.now = Date(timeIntervalSince1970: 0.2)
        await coordinator.recordError(modelID: modelID, callID: callID, error: LLMError.rateLimitExceeded)
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callID)

        let scheduler = ModelCallScheduler(
            maxConcurrent: 8,
            onPoolHealthChange: { payload in
                var enriched = payload
                let communication = await coordinator.poolCommunicationAggregatesSnapshot()
                enriched.errorRate = communication.errorRate
                enriched.rollingLatencyMsP50 = communication.rollingLatencyMsP50
                enriched.rollingLatencyMsP95 = communication.rollingLatencyMsP95
                enriched.budgetRemaining = await reporter.poolBudgetRemainingUSD()
                await capture.record(enriched)
            }
        )
        await scheduler.acquire(for: modelID, priority: .foreground)
        await scheduler.release(for: modelID)
        let snapshot = await capture.last
        #expect(snapshot?.errorRate != nil)
        #expect(snapshot?.rollingLatencyMsP50 != nil)
        #expect(snapshot?.rollingLatencyMsP95 != nil)
    }
}

// MARK: - ConversationStateSnapshotBuilder providers

private final class ProviderConversationStub: APILayerConversationManaging, @unchecked Sendable {
    let conversation: ModelConversation
    var orchestration: ConversationOrchestrationState?

    init(conversation: ModelConversation, orchestration: ConversationOrchestrationState?) {
        self.conversation = conversation
        self.orchestration = orchestration
    }

    func apiListConversationInfo() async -> [ModelConversation] { [conversation] }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func apiGetConversation(id: UUID) async -> ModelConversation? {
        conversation.id == id ? conversation : nil
    }
    func apiListCurrentMessages() async -> [Message] { [] }
    func apiListCurrentMessagesThrowing() async throws -> [Message] { [] }
    func apiGenerateFullSystemPrompt(withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        userSystemPrompt ?? ""
    }
    func apiSelectConversation(conversationID: UUID) async throws {}
    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode) async throws {}
    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?) async throws {}
    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {}
    func apiListAvailableTools() async throws -> [AvailableToolInfo] { [] }
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] { [] }
    func apiListSlashCommands() async throws -> [SlashCommandAutocompleteEntry] { [] }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {}
    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {}
    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {}
    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws {}
    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        let _ = (conversationID, hard)
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        let _ = query
        return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        let _ = query
        return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        let _ = (conversationID, patch)
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        let _ = (conversationID, patch, resolvedModel)
        return 0
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        let _ = (conversationID, userMessageID)
        return conversation.id
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        let _ = (parentConversationID, request, modelOverride)
        return UUID()
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        let _ = (conversationID, kinds)
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        let _ = (conversationID, kind)
        return nil
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        conversationID == conversation.id ? orchestration : nil
    }
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String { "" }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        _ = conversationID
        return 0
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = request
        return []
    }

    var currentConversationID: UUID? { get async { conversation.id } }
}

@Suite("ConversationStateSnapshotBuilder enrichment providers")
struct ConversationStateSnapshotBuilderProvidersTests {
    private static func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("activeCallProvider populates activeModelID/activeCallID")
    func activeCallProvider() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = ProviderConversationStub(conversation: convo, orchestration: nil)
        let activeModelID = UUID()
        let activeCallID = UUID()
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            activeCallProvider: { cid in
                #expect(cid == convo.id)
                return (activeModelID, activeCallID)
            }
        )
        #expect(payload.activeModelID == activeModelID)
        #expect(payload.activeCallID == activeCallID)
    }

    @Test("projectedCostProvider populates projectedCostUSD")
    func projectedCostProvider() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = ProviderConversationStub(conversation: convo, orchestration: nil)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            projectedCostProvider: { cid in
                #expect(cid == convo.id)
                return 9.99
            }
        )
        #expect(payload.projectedCostUSD == 9.99)
    }

    @Test("real budget ledger surfaces non-nil projectedCostUSD and pool budget remaining")
    func realBudgetLedgerSignals() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = ProviderConversationStub(conversation: convo, orchestration: nil)
        let ledger = DelegateCostLedger()
        let policy: BudgetPolicy = .enabled(
            maxUSDPerCall: nil,
            maxUSDPerConversation: 0.50,
            maxUSDGlobal: 1.00
        )

        try await ledger.authorize(
            policy: policy,
            modelID: model.id,
            conversationID: convo.id,
            accountID: nil,
            projectedCostUSD: 0.20
        )
        await ledger.recordCompletion(
            policy: policy,
            modelID: model.id,
            conversationID: convo.id,
            accountID: nil,
            actualCostUSD: 0.10
        )

        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            projectedCostProvider: { id in
                await ledger.projectedCostUSD(conversationID: id)
            }
        )
        #expect(payload.projectedCostUSD == 0.10)
        #expect(await ledger.poolBudgetRemainingUSD() == 0.90)
    }

    @Test("hydrated ledger seeds drive projectedCostUSD and pool budget remaining before dispatch")
    func hydratedBudgetLedgerSignals() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = ProviderConversationStub(conversation: convo, orchestration: nil)
        let ledger = DelegateCostLedger()
        await ledger.hydrate(from: [
            BudgetLedgerHydrationSeed(
                conversationID: convo.id,
                parentConversationID: nil,
                ownerAccountID: nil,
                spentUSD: 0.25
            )
        ])
        await ledger.setActivePolicy(.enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: 1.00))
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            projectedCostProvider: { id in
                await ledger.projectedCostUSD(conversationID: id)
            }
        )
        #expect(payload.projectedCostUSD == 0.25)
        #expect(await ledger.poolBudgetRemainingUSD() == 0.75)
    }

    @Test("orchestration-derived contextBudget populates when orchestration token fields present")
    func contextBudgetFromOrchestration() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let orch = ConversationOrchestrationState(
            agenticPhase: .idle,
            contextLimitTokens: 8192,
            remainingContextTokens: 7000,
            promptTokens: 1192
        )
        let stub = ProviderConversationStub(conversation: convo, orchestration: orch)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil
        )
        #expect(payload.contextBudget?.contextLimitTokens == 8192)
        #expect(payload.contextBudget?.remainingTokens == 7000)
        #expect(payload.contextBudget?.promptTokens == 1192)
    }

    @Test("projection budget provider overrides orchestration token budget")
    func contextBudgetProjectionProviderOverridesOrchestration() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let orch = ConversationOrchestrationState(
            agenticPhase: .idle,
            contextLimitTokens: 8192,
            remainingContextTokens: 7000,
            promptTokens: 1192
        )
        let stub = ProviderConversationStub(conversation: convo, orchestration: orch)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            projectionBudgetProvider: { cid in
                #expect(cid == convo.id)
                return ConversationContextBudget(
                    contextLimitTokens: 10_000,
                    promptTokens: 2_000,
                    remainingTokens: 8_000
                )
            }
        )
        #expect(payload.contextBudget?.contextLimitTokens == 10_000)
        #expect(payload.contextBudget?.promptTokens == 2_000)
        #expect(payload.contextBudget?.remainingTokens == 8_000)
    }

    @Test("projection budget provider nil falls back to orchestration token budget")
    func contextBudgetProjectionProviderFallsBackToOrchestration() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let orch = ConversationOrchestrationState(
            agenticPhase: .idle,
            contextLimitTokens: 4096,
            remainingContextTokens: 3000,
            promptTokens: 1096
        )
        let stub = ProviderConversationStub(conversation: convo, orchestration: orch)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            projectionBudgetProvider: { _ in nil }
        )
        #expect(payload.contextBudget?.contextLimitTokens == 4096)
        #expect(payload.contextBudget?.promptTokens == 1096)
        #expect(payload.contextBudget?.remainingTokens == 3000)
    }

    @Test("Nil optional providers leave enrichment fields absent")
    func nilProvidersLeaveNil() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = ProviderConversationStub(conversation: convo, orchestration: nil)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            activeCallProvider: nil,
            projectedCostProvider: nil
        )
        #expect(payload.activeModelID == nil)
        #expect(payload.activeCallID == nil)
        #expect(payload.projectedCostUSD == nil)
        #expect(payload.contextBudget == nil)
    }
}

// MARK: - models/registry subscribe snapshot regression

@Suite("models/registry subscribe snapshot regression")
struct ModelsRegistrySubscribeSnapshotRegressionTests {
    @Test("subscribeModelsRegistry sends snapshot envelope after cacheRegistrySnapshot")
    func subscribeReceivesSnapshotAfterCache() async throws {
        let hub = ModelStateTopicHub()
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "cached",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        await hub.cacheRegistrySnapshot(ModelsRegistryPayload(models: [model]))
        let collector = JSONCollector()
        let token = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        try await hub.subscribeModelsRegistry(token: token, since: nil)
        await hub.unregisterConnection(token)
        let lines = await collector.lines
        #expect(lines.count == 1)
        let data = lines[0].data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "snapshot")
        #expect(json?["topic"] as? String == ResourceTopicName.modelsRegistry)
        let value = json?["value"] as? [String: Any]
        let models = value?["models"] as? [Any]
        #expect(models?.count == 1)
    }
}

@Suite("Context engine projected context budget")
struct ContextEngineProjectedContextBudgetTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "budget-model",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("projectedContextBudget estimates prompt and remaining tokens from projected messages")
    func projectedBudgetBaseEstimate() async {
        let model = makeModel()
        var conversation = ModelConversation(model: model)
        conversation.model.maxContextLength = 2048
        let engine = DefaultContextEngine()
        let config = ConversationTransformConfiguration.default.contextCompaction
        let messages = [
            Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "world", timestamp: Date(), toolCalls: []),
        ]
        let expectedPrompt = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: messages,
            charactersPerToken: config.charactersPerToken
        )
        let budget = await engine.projectedContextBudget(
            request: ContextEngineProjectedContextBudgetRequest(
                messages: messages,
                conversation: conversation,
                compactionConfig: config,
                lastContextLimitTokens: 2048,
                lastPromptTokens: nil,
                projectionPolicy: nil
            )
        )
        #expect(budget?.contextLimitTokens == 2048)
        #expect(budget?.promptTokens == expectedPrompt)
        #expect(budget?.remainingTokens == max(0, 2048 - expectedPrompt))
    }

    @Test("projectedContextBudget applies projection policy before token budget calculation")
    func projectedBudgetUsesProjectionPolicy() async {
        let model = makeModel()
        var conversation = ModelConversation(model: model)
        conversation.model.maxContextLength = 1024
        let engine = DefaultContextEngine()
        let config = ConversationTransformConfiguration.default.contextCompaction
        let dropped = Message(
            id: UUID(),
            role: .user,
            content: String(repeating: "x", count: 400),
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: "low_trust"
        )
        let keptAssistant = Message(
            id: UUID(),
            role: .assistant,
            content: "assistant",
            timestamp: Date(),
            toolCalls: []
        )
        let keptLastUser = Message(
            id: UUID(),
            role: .user,
            content: "latest user",
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: "low_trust"
        )
        let messages = [dropped, keptAssistant, keptLastUser]
        let policy = ContextEngineProjectionPolicyInput(
            requestInputTrustRaw: "low_trust",
            safeDefaultTrustClass: .lowTrust,
            downgradeLowTrustContext: true
        )
        let projectedMessages = [keptAssistant, keptLastUser]
        let expectedPrompt = ContextCompactionPolicy.estimatedTotalPromptTokens(
            messages: projectedMessages,
            charactersPerToken: config.charactersPerToken
        )
        let budget = await engine.projectedContextBudget(
            request: ContextEngineProjectedContextBudgetRequest(
                messages: messages,
                conversation: conversation,
                compactionConfig: config,
                lastContextLimitTokens: 1024,
                lastPromptTokens: nil,
                projectionPolicy: policy
            )
        )
        #expect(budget?.promptTokens == expectedPrompt)
        #expect(budget?.remainingTokens == max(0, 1024 - expectedPrompt))
    }
}
